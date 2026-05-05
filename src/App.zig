
const std = @import("std");
const httpz = @import("httpz");
const zimit = @import("zimit");

const App = @This();

io: std.Io,
gpa: std.mem.Allocator,
archive_key: ?[]const u8,
zig_file_len: usize,
failure_ratelimit_s: usize,

map_arena: std.heap.ArenaAllocator,

failure_lock: std.Io.Mutex = .init,
failure_map: std.StringHashMapUnmanaged(std.Io.Timestamp) = .empty,
in_flight_lock: std.Io.Mutex = .init,
in_flight_map: std.StringHashMapUnmanaged(*InFlightRequest) = .empty,
global_limiter_lock: std.Io.Mutex = .init,
global_limiter: zimit.GlobalLimiter,

const default_rate_per_minute = 5;
const default_rate_burst = 2;
const default_zig_file_len = 32; // effectively 16, due to signatures
const default_failure_ratelimit_s = 120;

pub fn init(props: std.process.Init, clk: *zimit.SystemClock) !App {
    const global_limiter = try zimit.GlobalLimiter.init(.{
        .rate = if (props.environ_map.get("MIRRORS_RATE_PER_MINUTE")) |str|
            std.fmt.parseInt(u32, str, 0) catch default_rate_per_minute else
            default_rate_per_minute,
        .burst = if (props.environ_map.get("MIRRORS_RATE_BURST")) |str|
            std.fmt.parseInt(u32, str, 0) catch default_rate_burst else
            default_rate_burst,
        .per = .minute,
        .clock = clk.clock()
    });

    return .{
        .io = props.io,
        .gpa = props.gpa,
        .archive_key = props.environ_map.get("MIRRORS_ARCHIVE_KEY"),
        .zig_file_len = if (props.environ_map.get("MIRRORS_ZIG_FILE_LEN")) |str|
            std.fmt.parseInt(usize, str, 0) catch default_zig_file_len else
            default_zig_file_len,
        .failure_ratelimit_s = if (props.environ_map.get("MIRRORS_FAILURE_RATELIMIT_S")) |str|
            std.fmt.parseInt(usize, str, 0) catch default_failure_ratelimit_s else
            default_failure_ratelimit_s,
        .map_arena = std.heap.ArenaAllocator.init(props.gpa),
        .global_limiter = global_limiter
    };
}

pub fn deinit(app: *App) void {
    const allocator = app.map_arena.allocator();
    app.failure_map.deinit(allocator);
    app.in_flight_map.deinit(allocator);
    app.map_arena.deinit();
}

pub fn dispatch(app: *App, action: httpz.Action(*App), req: *httpz.Request, res: *httpz.Response) !void {
    std.log.info(">>> {s}", .{ req.url.path });
    try action(app, req, res);
}

pub fn uncaughtError(_: *App, _: *httpz.Request, res: *httpz.Response, err: anyerror) void {
    std.log.err("<<< {}", .{ err });

    res.status = switch (err) {
        error.Forbidden => 403,
        error.Canceled => 419,
        error.RateLimit => 429,
        error.FileNotFound => 404,
        error.UpstreamError => 504,
        error.SignatureVerificationFailed => 503,
        else => 500
    };
}

pub fn global_rate_limit(app: *App) !bool {
    try app.global_limiter_lock.lock(app.io);
    defer app.global_limiter_lock.unlock(app.io);
    return app.global_limiter.allow() == .denied;
}

pub fn auth(app: *App, header: []const u8) !void {
    std.log.info("X-Mirrors-Key: {s}", .{ header });
    const expected_key = app.archive_key orelse return error.Forbidden;
    if (!std.mem.eql(u8, expected_key, header)) return error.Forbidden;
}

pub fn now(app: *App) std.Io.Timestamp {
    return std.Io.Clock.boot.now(app.io);
}

pub const InFlightRequest = struct {
    lock: std.Io.RwLock = .init,
    references: usize
};

pub const InFlightIssue = enum {
    leader,
    follower
};

pub fn waitTag(app: *App, tag: []const u8) !InFlightIssue {
    var record = blk: {
        try app.in_flight_lock.lock(app.io);
        defer app.in_flight_lock.unlock(app.io);

        const existing_record = app.in_flight_map.get(tag) orelse {
            std.log.debug("thread {} waitTag {s} (leader)", .{ std.Thread.getCurrentId(), tag });

            const allocator = app.map_arena.allocator();
            const new_record = try allocator.create(InFlightRequest);
            errdefer allocator.destroy(new_record);
            new_record.* = .{ .references = 1 };

            const owned_tag = try allocator.dupe(u8, tag);
            errdefer allocator.free(owned_tag);

            try new_record.lock.lock(app.io); // lock until leader done
            try app.in_flight_map.put(allocator, owned_tag, new_record);
            return .leader;
        };

        existing_record.references += 1; // prevents deallocation
        break :blk existing_record;
    };

    std.log.debug("thread {} waitTag {s} (follower)", .{ std.Thread.getCurrentId(), tag });

    record.lock.lockShared(app.io) catch |err| {
        try app.in_flight_lock.lock(app.io);
        defer app.in_flight_lock.unlock(app.io);
        record.references -= 1; // clean-up
        return err;
    };

    record.lock.unlockShared(app.io);
    try app.completeTag(tag, .follower);
    return .follower;
}

pub fn completeTag(app: *App, tag: []const u8, issue: InFlightIssue) !void {
    try app.in_flight_lock.lock(app.io);
    defer app.in_flight_lock.unlock(app.io);

    const record = app.in_flight_map.get(tag) orelse return;
    record.references -= 1;

    std.log.debug("thread {} completeTag {s}", .{ std.Thread.getCurrentId(), tag });

    if (issue == .leader)
        record.lock.unlock(app.io);

    if (record.references == 0) {
        const allocator = app.map_arena.allocator();
        const entry = app.in_flight_map.fetchRemove(tag);
        allocator.free(entry.?.key); // lock protected
        allocator.destroy(record);
    }
}
