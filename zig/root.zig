
const std = @import("std");
const httpz = @import("httpz");
const minizign = @import("minizign");
const lib = @import("lib");

const failure_timeout_s = 120;

pub fn get(app: *lib.App, req: *httpz.Request, res: *httpz.Response) !void {
    const begin = std.Io.Clock.boot.now(app.io);
    const triple = req.param("triple") orelse return error.NotFound;
    const version = lib.tools.extractVersion(triple) orelse return error.NotFound;
    std.log.info(">>> {s} ({s})", .{ triple, version });

    const upstream_uri = try std.fmt.allocPrint(req.arena, "https://ziglang.org/download/{s}/{s}", .{ version, triple });

    // always redirect signature to source
    if (std.mem.eql(u8, std.fs.path.extension(upstream_uri), ".minisig")) {
        res.status = 301;
        res.header("Location", upstream_uri);
        return;
    }

    failure: {
        try app.failure_lock.lock(app.io);
        defer app.failure_lock.unlock(app.io);

        const timestamp = app.failure_map.get(upstream_uri) orelse break :failure;
        const now = std.Io.Clock.boot.now(app.io).toSeconds();
        if (now - timestamp < failure_timeout_s) return error.RateLimit;

        _ = app.failure_map.remove(upstream_uri);
    }

    const cache_path = try std.fmt.allocPrint(req.arena, "mirror-zig/{s}", .{ triple });

    lib.cache.serve(app, res, upstream_uri, cache_path, validate_file) catch |err| switch (err) {
        error.FileNotFound => {
            try lib.cache.fetch(app, req.arena, upstream_uri, cache_path);
            try lib.cache.serve(app, res, upstream_uri, cache_path, validate_file);
            res.header("X-Cache-Status", "MISS");

            const end = std.Io.Clock.boot.now(app.io);
            std.log.info("<<< from upstream (took {}s)", .{ begin.durationTo(end).toSeconds() });
            return;
        },
        else => return err
    };

    res.header("X-Cache-Status", "HIT");
    const end = std.Io.Clock.boot.now(app.io);
    std.log.info("<<< from cache (took {}s)", .{ begin.durationTo(end).toSeconds() });
}

const minisign_key = std.mem.trim(u8, @embedFile("minisign"), "\n\r");
const public_key = minizign.PublicKey.decodeFromBase64(minisign_key) catch unreachable;

fn validate_file(app: *lib.App, arena: std.mem.Allocator, upstream_uri: []const u8, fd: std.Io.File) !void {
    const signature_str = blk: {
        const minisig_uri = try std.fmt.allocPrint(arena, "{s}.minisig", .{ upstream_uri });
        const issue = try app.waitTag(minisig_uri);

        defer if (issue == .leader) {
            app.completeTag(minisig_uri, .leader) catch |err| std.log.err("completeTag {}", .{ err });
        };

        break :blk app.signature_map.get(upstream_uri) orelse ftch: {
            std.log.debug("fetching {s}...", .{ minisig_uri });

            const uri = try std.Uri.parse(minisig_uri);
            var http_client = std.http.Client { .io = app.io, .allocator = arena };
            defer http_client.deinit();
            var request = try http_client.request(.GET, uri, .{});
            request.headers.user_agent = .{ .override = lib.tools.user_agent };
            defer request.deinit();

            var response = try lib.tools.httpPreflightRequest(&request);

            var buffer: [1024]u8 = undefined;
            const reader = response.reader(&buffer);
            const response_str = try reader.allocRemaining(app.gpa, @enumFromInt(4 * 1024));

            try app.signature_map.put(app.gpa, upstream_uri, response_str);
            break :ftch response_str;
        };
    };

    std.log.debug("verifiying {s}...", .{ upstream_uri });

    const sig = try minizign.Signature.decode(arena, signature_str);
    try public_key.verifyFile(arena, app.io, fd, sig, null);
}
