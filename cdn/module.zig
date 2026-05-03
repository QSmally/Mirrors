
const std = @import("std");
const httpz = @import("httpz");
const lib = @import("lib");

pub fn get(app: *lib.App, req: *httpz.Request, res: *httpz.Response) !void {
    const begin = std.Io.Clock.boot.now(app.io);
    const id = req.param("id") orelse return error.NotFound;
    const cdn_path = whitelist.get(id) orelse return error.NotFound;
    std.log.info(">>> {s}", .{ cdn_path });

    try lib.cache.serve(app, res, "", cdn_path, lib.cache.no_validation);

    const end = std.Io.Clock.boot.now(app.io);
    std.log.info("<<< from cdn (took {}s)", .{ begin.durationTo(end).toSeconds() });
}

const whitelist = std.StaticStringMap([]const u8).initComptime(&.{
    .{ "thesaurus.zip", "cdn/thesaurus.zip" }
});
