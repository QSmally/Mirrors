
const std = @import("std");
const httpz = @import("httpz");
const mirrorZig = @import("mirror_zig");

const port = 80;

pub fn main(init: std.process.Init) !void {
    server = try httpz.Server(*Mirrorer).init(init.io, init.gpa, .{
        .address = .all(port),
    }, &mirrorer);

    defer server.deinit();
    register_signal(.INT, on_signal);
    register_signal(.TERM, on_signal);

    var router = try server.router(.{});
    router.get("/", getStaticFile(@embedFile("mirrors.qsmally.org/index.html")), .{});
    router.get("/index.html", getStaticFile(@embedFile("mirrors.qsmally.org/index.html")), .{});
    router.get("/styling.css", getStaticFile(@embedFile("mirrors.qsmally.org/styling.css")), .{});
    router.get("/profile.png", getStaticFile(@embedFile("mirrors.qsmally.org/profile.png")), .{});
    router.get("/favicon.ico", getStaticFile(@embedFile("mirrors.qsmally.org/favicon.ico")), .{});

    router.get("/contact", redirectTo("mailto:info@qsmally.org"), .{});
    router.get("/home", redirectTo("https://qsmally.org"), .{});
    router.get("/mirror", redirectTo("https://github.com/QSmally/Mirrors"), .{});
    router.get("/privacy", redirectTo("https://qsmally.org/privacy"), .{});

    var mirrorZigInst = Mirrorer {};
    router.get("/zig/:triple", mirrorZig.get, .{ .handler = &mirrorZigInst });

    std.log.info("listening on port {}", .{ port });

    try server.listen();
}

var mirrorer: Mirrorer = .{};
var server: httpz.Server(*Mirrorer) = undefined;

fn register_signal(signal: std.posix.SIG, handler: anytype) void {
    const sigaction = std.posix.Sigaction {
        .handler = .{ .handler = handler },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.SIGINFO };
    std.posix.sigaction(signal, &sigaction, null);
}

fn on_signal(signal: std.posix.SIG) callconv(.c) void {
    std.log.info("received signal {}, exiting...", .{ @intFromEnum(signal) });
    mirrorer.deinit();
    server.stop();
}

const HttpzRoute = *const fn (*Mirrorer, *httpz.Request, *httpz.Response) anyerror!void;

fn getStaticFile(comptime content: []const u8) HttpzRoute {
    return struct {
        fn getStaticFile(_: *Mirrorer, _: *httpz.Request, res: *httpz.Response) !void {
            res.body = content;
        }
    }.getStaticFile;
}

fn redirectTo(comptime location: []const u8) HttpzRoute {
    return struct {
        fn redirectTo(_: *Mirrorer, _: *httpz.Request, res: *httpz.Response) !void {
            res.status = 301;
            res.header("Location", location);
        }
    }.redirectTo;
}

pub const Mirrorer = struct {

    pub fn deinit(srv: *Mirrorer) void {
        _ = srv;
    }
};
