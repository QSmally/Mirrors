
const std = @import("std");
const httpz = @import("httpz");
const minizign = @import("minizign");
const lib = @import("lib");

pub fn get(app: *lib.App, req: *httpz.Request, res: *httpz.Response) !void {
    const begin = app.now();
    const triple = req.param("triple") orelse return error.FileNotFound;
    const version = lib.tools.extractVersion(triple) orelse return error.FileNotFound;
    if (std.mem.startsWith(u8, triple, ".")) return error.FileNotFound;

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
        if (timestamp.durationTo(app.now()).toSeconds() < app.failure_ratelimit_s) return error.RateLimit;

        const allocator = app.map_arena.allocator();
        const entry = app.failure_map.fetchRemove(upstream_uri);
        if (entry) |the_entry| allocator.free(the_entry.key);
    }

    const cache_path = try std.fmt.allocPrint(req.arena, "{s}/{s}", .{ archive, triple });

    lib.cache.serve(app, res, cache_path, validate_file, upstream_uri) catch |err| switch (err) {
        error.FileNotFound => {
            if (try app.global_rate_limit())
                return error.RateLimit;

            if (try lib.cache.directory_len(app.io, archive) > app.zig_file_len)
                return error.RateLimit;

            try lib.cache.fetch(app, req.arena, upstream_uri, cache_path);
            try lib.cache.serve(app, res, cache_path, validate_file, upstream_uri);
            res.header("X-Cache-Status", "MISS");

            std.log.info("<<< from upstream (took {}s)", .{ begin.durationTo(app.now()).toSeconds() });
            return;
        },
        error.SignatureVerificationFailed => |the_err| {
            res.header("X-Cache-Status", "UPDATING");
            lib.tools.cwd.deleteFile(app.io, cache_path) catch |err2| std.log.warn("deleteFile {s} {}", .{ cache_path, err2 });

            const minisig_path = try std.fmt.allocPrint(req.arena, "{s}.minisig", .{ cache_path });
            lib.tools.cwd.deleteFile(app.io, minisig_path) catch |err2| std.log.warn("deleteFile {s} {}", .{ minisig_path, err2 });
            return the_err;
        },
        else => return err
    };

    res.header("X-Cache-Status", "HIT");
    std.log.info("<<< from cache (took {}s)", .{ begin.durationTo(app.now()).toSeconds() });
}

const minisign_key = std.mem.trim(u8, @embedFile("minisign"), "\n\r");
const public_key = minizign.PublicKey.decodeFromBase64(minisign_key) catch unreachable;

fn validate_file(app: *lib.App, arena: std.mem.Allocator, fd: std.Io.File, upstream_uri: anytype) !void {
    std.log.debug("verifiying {s}...", .{ upstream_uri });
    const minisig_path = try std.fmt.allocPrint(arena, "{s}/{s}.minisig", .{ archive, std.fs.path.basename(upstream_uri) });

    const signature = minizign.Signature.fromFile(arena, minisig_path, app.io) catch |err| switch (err) {
        error.FileNotFound => blk: {
            const minisig_uri_str = try std.fmt.allocPrint(arena, "{s}.minisig", .{ upstream_uri });
            const issue = try app.waitTag(minisig_uri_str);

            defer if (issue == .leader) {
                app.completeTag(minisig_uri_str, .leader) catch |err2| std.log.err("completeTag {}", .{ err2 });
            };

            if (issue == .leader) {
                const minisig_uri = try std.Uri.parse(minisig_uri_str);
                const file = try lib.http.toFileAtomic(app.io, arena, minisig_uri, minisig_path);
                defer file.close(app.io);
            }

            break :blk try minizign.Signature.fromFile(arena, minisig_path, app.io);
        },
        else => return err
    };

    try public_key.verifyFile(arena, app.io, fd, signature, null);
}

const archive = "mirror-zig";
