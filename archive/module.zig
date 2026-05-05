
const std = @import("std");
const httpz = @import("httpz");
const lib = @import("lib");

pub fn get(app: *lib.App, req: *httpz.Request, res: *httpz.Response) !void {
    const begin = app.now();
    const id = req.param("id") orelse return error.FileNotFound;
    if (std.mem.startsWith(u8, id, ".")) return error.FileNotFound;

    const archive_path = try std.fmt.allocPrint(req.arena, "mirror-archive/{s}", .{ id });

    lib.cache.serve(app, res, archive_path, lib.cache.no_validation, void) catch |err| switch (err) {
        error.FileNotFound => {
            const key = req.header("x-mirrors-key") orelse return error.Forbidden;
            try app.auth(key);

            const upstream_url = req.header("x-upstream-url") orelse return error.Forbidden;
            std.log.debug("fetching to archive {s}...", .{ upstream_url });

            const uri = try std.Uri.parse(upstream_url);
            const file = try lib.http.toFileAtomic(app.io, req.arena, uri, archive_path);
            defer file.close(app.io);

            const archive_upstream_path = try std.fmt.allocPrint(req.arena, "{s}.upstream", .{ archive_path });

            try lib.tools.write(app.io, archive_upstream_path, upstream_url);
            try lib.cache.serve(app, res, archive_path, lib.cache.no_validation, void);

            std.log.info("<<< from archive upstream (took {}s)", .{ begin.durationTo(app.now()).toSeconds() });
            return;
        },
        else => return err
    };

    std.log.info("<<< from archive (took {}s)", .{ begin.durationTo(app.now()).toSeconds() });
}
