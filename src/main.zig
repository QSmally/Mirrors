
const std = @import("std");
const httpz = @import("httpz");
const zimit = @import("zimit");
const mirrorZig = @import("mirror_zig");
const mirrorArchive = @import("mirror_archive");

pub fn main(init: std.process.Init) !void {
    var clk = zimit.SystemClock.init(init.io);
    var app = try App.init(init, &clk);
    defer app.deinit();

    std.log.debug("init with archive_key={?s}", .{ app.archive_key });

    server = try httpz.Server(*App).init(init.io, init.gpa, .{
        .address = .all(options.port),
    }, &app);

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

    router.get("/zig/:triple", mirrorZig.get, .{});
    router.get("/archive/:id", mirrorArchive.get, .{});

    std.log.info("listening on port {}", .{ options.port });

    try server.listen();
}

var server: httpz.Server(*App) = undefined;

fn register_signal(signal: std.posix.SIG, handler: anytype) void {
    const sigaction = std.posix.Sigaction {
        .handler = .{ .handler = handler },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.SIGINFO };
    std.posix.sigaction(signal, &sigaction, null);
}

fn on_signal(signal: std.posix.SIG) callconv(.c) void {
    std.log.info("received signal {}, exiting...", .{ @intFromEnum(signal) });
    server.stop();
}

const HttpzRoute = *const fn (*App, *httpz.Request, *httpz.Response) anyerror!void;

fn getStaticFile(comptime content: []const u8) HttpzRoute {
    return struct {
        fn getStaticFile(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
            res.body = content;
        }
    }.getStaticFile;
}

fn redirectTo(comptime location: []const u8) HttpzRoute {
    return struct {
        fn redirectTo(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
            res.status = 301;
            res.header("Location", location);
        }
    }.redirectTo;
}

pub const App = @import("App.zig");
pub const cache = @import("cache.zig");
pub const http = @import("http.zig");
pub const options = @import("options");
pub const tools = @import("tools.zig");

test {
    std.testing.refAllDecls(@This());
}
