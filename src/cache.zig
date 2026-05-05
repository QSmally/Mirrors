
const std = @import("std");
const tools = @import("tools.zig");
const App = @import("App.zig");
const httpz = @import("httpz");
const http = @import("http.zig");
const options = @import("options");

pub fn fetch(app: *App, arena: std.mem.Allocator, upstream_uri: []const u8, dest_path: []const u8) !void {
    if (try app.waitTag(upstream_uri) == .follower)
        return;
    defer app.completeTag(upstream_uri, .leader) catch |err| std.log.err("completeTag {}", .{ err });

    std.log.debug("fetching {s}...", .{ upstream_uri });

    const file = http.toFileAtomic(app.io, arena, try std.Uri.parse(upstream_uri), dest_path) catch |err| {
        try app.failure_lock.lock(app.io);
        defer app.failure_lock.unlock(app.io);

        const allocator = app.map_arena.allocator();
        const owned_upstream_uri = try allocator.dupe(u8, upstream_uri);
        try app.failure_map.put(allocator, owned_upstream_uri, app.now());
        return err;
    };
    defer file.close(app.io);

    const stat = try file.stat(app.io);
    std.log.info("saved {} bytes to {s}", .{ stat.size, dest_path });
}

pub fn directory_len(io: std.Io, dir_path: []const u8) !usize {
    const dir = try tools.cwd.openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var iterator = dir.iterate();
    var len: usize = 0;

    while (try iterator.next(io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, ".") or entry.kind != .file)
            continue;
        len += 1;
    }

    return len;
}

const validate = *const fn (*App, std.mem.Allocator, std.Io.File, anytype) anyerror!void;

pub fn serve(app: *App, res: *httpz.Response, path: []const u8, comptime validate_file: validate, context: anytype) !void {
    const file = try tools.cwd.openFile(app.io, path, .{ .allow_directory = false });
    defer file.close(app.io);

    std.log.debug("returning {s}...", .{ path });

    try validate_file(app, res.arena, file, context);

    res.header("Cache-Control", "max-age=7776000,public,immutable"); // 90 days
    res.content_type = .BINARY;

    var file_buffer: [256 * 1024]u8 = undefined;
    var reader = file.reader(app.io, &file_buffer);
    _ = try reader.interface.streamRemaining(res.writer());
}

pub fn no_validation(_: *App, _: std.mem.Allocator, _: std.Io.File, _: anytype) !void {}
