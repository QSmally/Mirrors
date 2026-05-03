
const std = @import("std");
const tools = @import("tools.zig");
const App = @import("App.zig");
const httpz = @import("httpz");
const options = @import("options");

const cwd = std.Io.Dir.cwd();

pub fn fetch(app: *App, arena: std.mem.Allocator, upstream_uri: []const u8, dest_path: []const u8) !void {
    if (try app.waitTag(upstream_uri) == .follower)
        return;
    defer app.completeTag(upstream_uri, .leader) catch |err| std.log.err("completeTag {}", .{ err });

    const dir_path = std.fs.path.dirname(dest_path) orelse "/tmp";
    try housekeeping(app, dir_path);

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

    const tmp_path = try std.fmt.allocPrint(arena, "{s}/.tmp.{s}", .{ dir_path, std.fs.path.basename(dest_path) });
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

var prng = std.Random.DefaultPrng.init(1234);
const random = prng.random();

pub fn housekeeping(app: *App, dir_path: []const u8) !void {
    if (!app.housekeeping_lock.tryLock())
        return;
    defer app.housekeeping_lock.unlock(app.io);

    const now = std.Io.Clock.boot.now(app.io);

    if (app.housekeeping_last_sweep.durationTo(now).toSeconds() < options.housekeeping_s)
        return;
    std.log.debug("housekeeping...", .{});

    const dir = try cwd.openDir(app.io, dir_path, .{ .iterate = true });
    defer dir.close(app.io);

    var iterator = dir.iterate();
    var list: std.ArrayList([]const u8) = .empty;

    defer {
        for (list.items) |file_name|
            app.gpa.free(file_name);
        list.deinit(app.gpa);
    }

    while (try iterator.next(app.io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, ".") or entry.kind != .file)
            continue;
        const file_name = try app.gpa.dupe(u8, entry.name);
        errdefer app.gpa.free(file_name);

        try list.append(app.gpa, file_name);
    }

    std.log.debug("housekeeping counted {} files", .{ list.items.len });

    while (list.items.len >= options.housekeeping_len) {
        const random_idx = random.intRangeLessThan(usize, 0, list.items.len);
        const file_name = list.swapRemove(random_idx);
        defer app.gpa.free(file_name);

        std.log.info("housekeeping to remove {s} ({} total)", .{ file_name, list.items.len });
        dir.deleteFile(app.io, file_name) catch |err| std.log.warn("deleteFile {s} {}", .{ file_name, err });
    }

    app.housekeeping_last_sweep = now;
}

const validate = *const fn (*App, std.mem.Allocator, []const u8, std.Io.File) anyerror!void;

pub fn serve(app: *App, res: *httpz.Response, upstream_uri: []const u8, path: []const u8, validate_file: validate) !void {
    const file = try cwd.openFile(app.io, path, .{ .allow_directory = false });
    defer file.close(app.io);

    std.log.debug("returning {s}...", .{ path });

    validate_file(app, res.arena, upstream_uri, file) catch |err| {
        if (err == error.SignatureVerificationFailed) {
            cwd.deleteFile(app.io, path) catch |d_err| std.log.warn("deleteFile {s} {}", .{ path, d_err });
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
