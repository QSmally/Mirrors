
const std = @import("std");
const httpz = @import("httpz");
const minizign = @import("minizign");
const lib = @import("lib");

pub fn get(srv: *lib.Mirrorer, req: *httpz.Request, res: *httpz.Response) !void {
    const triple = req.param("triple") orelse return error.NotFound;
    const version = lib.extractVersion(triple) orelse return error.NotFound;
    std.log.debug("{s}: {s}/{s}", .{ req.url.path, triple, version });

    const zig_url = try std.fmt.allocPrint(req.arena, "https://ziglang.org/download/{s}/{s}", .{ version, triple });

    if (std.mem.eql(u8, std.fs.path.extension(zig_url), ".minisig")) {
        res.status = 301;
        res.header("Location", zig_url);
        return;
    }

    const cache_path = try std.fmt.allocPrint(req.arena, "mirror-zig/{s}", .{ triple });

    serve_file(srv, res, zig_url, cache_path) catch |err| switch (err) {
        error.FileNotFound => {
            try fetch_file(srv.io, req.arena, zig_url, cache_path);
            try serve_file(srv, res, zig_url, cache_path);
            return;
        },
        else => return err
    };
}

const cwd = std.Io.Dir.cwd();

fn fetch_file(io: std.Io, allocator: std.mem.Allocator, uri_path: []const u8, dest: []const u8) !void {
    std.log.debug("fetching {s}", .{ uri_path });

    const uri = try std.Uri.parse(uri_path);
    var http_client = std.http.Client { .io = io, .allocator = allocator };
    defer http_client.deinit();
    var fetch = try http_client.request(.GET, uri, .{});
    defer fetch.deinit();

    try fetch.sendBodiless();

    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = try fetch.receiveHead(&redirect_buf);
    if (response.head.status != .ok) return error.ZigUnavailable;

    if (std.fs.path.dirname(dest)) |dir| {
        cwd.createDirPath(io, dir) catch {};
    }

    const file = try cwd.createFile(io, dest, .{});
    defer file.close(io);

    var read_buf: [2 * 1024 * 1024]u8 = undefined;
    const rdr = response.reader(&read_buf);
    var write_buf: [2 * 1024 * 1024]u8 = undefined;
    var wrt = file.writer(io, &write_buf);

    _ = try rdr.streamRemaining(&wrt.interface);
    try wrt.interface.flush();
    std.log.debug("saved to {s}", .{ dest });
}

fn serve_file(srv: *lib.Mirrorer, res: *httpz.Response, zig_url: []const u8, path: []const u8) !void {
    std.log.debug("serving {s}", .{ path });

    const file = try cwd.openFile(srv.io, path, .{ .allow_directory = false });
    defer file.close(srv.io);

    try validate_file(srv, res.arena, zig_url, file);

    const stat = try file.stat(srv.io);
    var buf: [32]u8 = undefined;
    const len_str = try std.fmt.bufPrint(&buf, "{d}", .{ stat.size });
    res.header("Content-Length", len_str);

    res.header("Cache-Control", "max-age=7776000,public,immutable"); // 90 days
    res.content_type = .BINARY;

    var file_buf: [256 * 1024]u8 = undefined;
    var reader = file.reader(srv.io, &file_buf);
    _ = try reader.interface.streamRemaining(res.writer());
}

const minisign_key = std.mem.trim(u8, @embedFile("minisign"), "\n\r");
const public_key = minizign.PublicKey.decodeFromBase64(minisign_key) catch unreachable;

fn validate_file(srv: *lib.Mirrorer, arena: std.mem.Allocator, url: []const u8, fd: std.Io.File) !void {
    const signature_str = srv.signatures.get(url) orelse blk: {
        const minisig_url = try std.fmt.allocPrint(arena, "{s}.minisig", .{ url });
        std.log.debug("fetching {s}", .{ minisig_url });

        const uri = try std.Uri.parse(minisig_url);
        var http_client = std.http.Client { .io = srv.io, .allocator = arena };
        defer http_client.deinit();
        var fetch = try http_client.request(.GET, uri, .{});
        defer fetch.deinit();

        try fetch.sendBodiless();

        var redirect_buf: [8 * 1024]u8 = undefined;
        var response = try fetch.receiveHead(&redirect_buf);
        if (response.head.status != .ok) return error.ZigUnavailable;

        var read_buf: [2 * 1024 * 1024]u8 = undefined;
        const rdr = response.reader(&read_buf);
        const fetched = try rdr.allocRemaining(srv.gpa, @enumFromInt(16 * 1024));

        try srv.signatures.put(srv.gpa, url, fetched);
        break :blk fetched;
    };

    std.log.debug("verifiying {s}", .{ url });

    const sig = try minizign.Signature.decode(arena, signature_str);
    try public_key.verifyFile(arena, srv.io, fd, sig, null);
}
