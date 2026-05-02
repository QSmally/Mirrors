
const std = @import("std");
const httpz = @import("httpz");
const mirrorZig = @import("mirror_zig");

const port = 80;

pub fn main(init: std.process.Init) !void {
    mirrorer = .{ .io = init.io, .gpa = init.gpa };

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

    router.get("/zig/:triple", mirrorZig.get, .{ .handler = &mirrorer });

    std.log.info("listening on port {}", .{ port });

    try server.listen();
}

var mirrorer: Mirrorer = undefined;
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

    io: std.Io,
    gpa: std.mem.Allocator,

    signatures: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn deinit(srv: *Mirrorer) void {
        var iterator = srv.signatures.iterator();
        while (iterator.next()) |entry|
            srv.gpa.free(entry.value_ptr.*);
        srv.signatures.deinit(srv.gpa);
    }
};

pub fn extractVersion(filename: []const u8) ?[]const u8 {
    var start: usize = 0;

    while (start < filename.len) : (start += 1) {
        if (std.ascii.isDigit(filename[start])) {
            var end = start;
            var dots: usize = 0;

            while (end < filename.len) {
                if (filename[end] == '.')
                    dots += 1;
                if (dots < 3) end += 1 else break;
            }

            const proposal = filename[start..end];
            _ = std.SemanticVersion.parse(proposal) catch continue;
            return proposal;
        }
    }
    return null;
}

test extractVersion {
    try std.testing.expectEqualSlices(u8, extractVersion("zig-0.16.0").?, "0.16.0");
    try std.testing.expectEqualSlices(u8, extractVersion("zig-0.16.0.tar.gz").?, "0.16.0");
    try std.testing.expectEqualSlices(u8, extractVersion("zig-0.16.0.tar.gz").?, "0.16.0");
    try std.testing.expectEqualSlices(u8, extractVersion("zig-aarch64-0.16.0.tar.gz").?, "0.16.0");
    try std.testing.expectEqual(extractVersion("zig-0.16"), null);
    try std.testing.expectEqual(extractVersion("zig"), null);
}
