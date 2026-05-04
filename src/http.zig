
const builtin = @import("builtin");
const pkg = @import("build.zig.zon");
const std = @import("std");
const tools = @import("tools.zig");

pub fn toFileAtomic(io: std.Io, arena: std.mem.Allocator, uri: std.Uri, dest_path: []const u8) !std.Io.File {
    var http_client = std.http.Client { .io = io, .allocator = arena };
    defer http_client.deinit();
    var request = try http_client.request(.GET, uri, .{});
    request.headers.user_agent = .{ .override = user_agent };
    defer request.deinit();

    std.log.debug("connecting to {s}...", .{ if (uri.host) |host| host.percent_encoded else "unknown" });

    var response = try preflightRequest(&request);

    const tmp_path = try std.fmt.allocPrint(arena, "{s}/.tmp.{s}", .{
        std.fs.path.dirname(dest_path) orelse "/tmp",
        std.fs.path.basename(dest_path) });
    const file = try tools.cwd.createFile(io, tmp_path, .{});
    errdefer tools.cwd.deleteFile(io, tmp_path) catch |err| std.log.warn("deleteFile {s} {}", .{ tmp_path, err });

    std.log.debug("downloading to {s}...", .{ tmp_path });

    var read_buffer: [512 * 1024]u8 = undefined;
    const reader = response.reader(&read_buffer);
    var write_buffer: [512 * 1024]u8 = undefined;
    var writer = file.writer(io, &write_buffer);

    _ = try reader.streamRemaining(&writer.interface);
    try writer.interface.flush();

    std.log.debug("atomically renaming to {s}...", .{ dest_path });
    try tools.cwd.rename(tmp_path, tools.cwd, dest_path, io);
    return file;
}

pub fn preflightRequest(request: *std.http.Client.Request) !std.http.Client.Response {
    try request.sendBodiless();

    var buffer: [8 * 1024]u8 = undefined;
    const response = try request.receiveHead(&buffer);

    return switch (response.head.status) {
        .ok => response,
        .not_found => error.FileNotFound,
        else => error.UpstreamError
    };
}

pub const user_agent = std.fmt.comptimePrint("Mirrors/{s} (mirrors.qsmally.org) Zig/{s}", .{
    pkg.version,
    builtin.zig_version_string });
