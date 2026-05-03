
const std = @import("std");
const tools = @import("tools.zig");
const App = @import("App.zig");
const httpz = @import("httpz");

const cwd = std.Io.Dir.cwd();

pub fn fetch(app: *App, arena: std.mem.Allocator, upstream_uri: []const u8, dest_path: []const u8) !void {
    if (try app.waitTag(upstream_uri) == .follower)
        return;
    defer app.completeTag(upstream_uri, .leader) catch |err| std.log.err("completeTag {}", .{ err });
    std.log.debug("fetching {s}...", .{ upstream_uri });

    const uri = try std.Uri.parse(upstream_uri);
    var http_client = std.http.Client { .io = app.io, .allocator = arena };
    defer http_client.deinit();
    var request = try http_client.request(.GET, uri, .{});
    request.headers.user_agent = .{ .override = tools.user_agent };
    defer request.deinit();

    var response = tools.httpPreflightRequest(&request) catch |err| {
        try app.failure_lock.lock(app.io);
        defer app.failure_lock.unlock(app.io);
        try app.failure_map.put(app.gpa, upstream_uri, std.Io.Clock.boot.now(app.io).toSeconds());
        return err;
    };

    const tmp_path = try std.fmt.allocPrint(arena, "{s}/.tmp.{s}", .{ std.fs.path.dirname(dest_path) orelse "/tmp", std.fs.path.basename(dest_path) });
    const file = try cwd.createFile(app.io, tmp_path, .{});
    errdefer cwd.deleteFile(app.io, tmp_path) catch {};
    defer file.close(app.io);

    std.log.debug("downloading to {s}...", .{ tmp_path });

    var read_buffer: [512 * 1024]u8 = undefined;
    const reader = response.reader(&read_buffer);
    var write_buffer: [512 * 1024]u8 = undefined;
    var writer = file.writer(app.io, &write_buffer);

    const bytes = try reader.streamRemaining(&writer.interface);
    try writer.interface.flush();

    std.log.debug("atomically renaming to {s}...", .{ dest_path });
    try cwd.rename(tmp_path, cwd, dest_path, app.io);

    std.log.info("saved {} bytes to {s}", .{ bytes, dest_path });
}

const validate = *const fn (*App, std.mem.Allocator, []const u8, std.Io.File) anyerror!void;

pub fn serve(app: *App, res: *httpz.Response, upstream_uri: []const u8, path: []const u8, validate_file: validate) !void {
    const file = try cwd.openFile(app.io, path, .{ .allow_directory = false });
    defer file.close(app.io);

    std.log.debug("returning {s}...", .{ path });

    validate_file(app, res.arena, upstream_uri, file) catch |err| {
        if (err == error.SignatureVerificationFailed) {
            try cwd.deleteFile(app.io, path);
            res.header("X-Cache-Status", "UPDATING");
        }

        return err;
    };

    res.header("Cache-Control", "max-age=7776000,public,immutable"); // 90 days
    res.content_type = .BINARY;

    var file_buffer: [256 * 1024]u8 = undefined;
    var reader = file.reader(app.io, &file_buffer);
    _ = try reader.interface.streamRemaining(res.writer());
}
