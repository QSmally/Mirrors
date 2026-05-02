
const std = @import("std");
const httpz = @import("httpz");
const minizign = @import("minizign");
const lib = @import("lib");

pub fn get(srv: *lib.Mirrorer, req: *httpz.Request, res: *httpz.Response) !void {
    std.log.debug("path: {s}", .{ req.url.path });
    _ = res;
    _ = srv;
}
