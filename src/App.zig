
const std = @import("std");
const httpz = @import("httpz");

const App = @This();

io: std.Io,
gpa: std.mem.Allocator,
archive_key: ?[]const u8,
zig_file_len: usize,
failure_ratelimit_s: usize,

failure_lock: std.Io.Mutex = .init,
failure_map: std.StringHashMapUnmanaged(i64) = .empty,
in_flight_lock: std.Io.Mutex = .init,
in_flight_map: std.StringHashMapUnmanaged(*InFlightRequest) = .empty,

const default_zig_file_len = 32; // effectively 16, due to signatures
const default_failure_ratelimit_s = 120;

pub fn init(props: std.process.Init) App {
    return .{
        .io = props.io,
        .gpa = props.gpa,
        .archive_key = props.environ_map.get("MIRRORS_ARCHIVE_KEY"),
        .zig_file_len = if (props.environ_map.get("MIRRORS_ZIG_FILE_LEN")) |str|
            std.fmt.parseInt(usize, str, 0) catch default_zig_file_len else
            default_zig_file_len,
        .failure_ratelimit_s = if (props.environ_map.get("MIRRORS_FAILURE_RATELIMIT_S")) |str|
            std.fmt.parseInt(usize, str, 0) catch default_failure_ratelimit_s else
            default_failure_ratelimit_s
    };
}

pub fn deinit(app: *App) void {
    app.failure_map.deinit(app.gpa);

    var iterator2 = app.in_flight_map.iterator();
    while (iterator2.next()) |entry|
        app.gpa.destroy(entry.value_ptr.*);
    app.in_flight_map.deinit(app.gpa);
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

pub fn auth(app: *App, header: []const u8) !void {
    std.log.debug("X-Mirrors-Key: {s}", .{ header });
    const expected_key = app.archive_key orelse return error.Forbidden;
    if (!std.mem.eql(u8, expected_key, header)) return error.Forbidden;
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

        var existing_record = app.in_flight_map.get(tag) orelse {
            std.log.debug("thread {} waitTag {s} (leader)", .{ std.Thread.getCurrentId(), tag });

            const new_record = try app.gpa.create(InFlightRequest);
            errdefer app.gpa.destroy(new_record);
            new_record.* = .{ .references = 1 };

            try new_record.lock.lock(app.io);
            try app.in_flight_map.put(app.gpa, tag, new_record);
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

    var record = app.in_flight_map.get(tag) orelse return;
    record.references -= 1;

    std.log.debug("thread {} completeTag {s}", .{ std.Thread.getCurrentId(), tag });

    if (issue == .leader)
        record.lock.unlock(app.io);

    if (record.references == 0) {
        _ = app.in_flight_map.remove(tag);
        app.gpa.destroy(record);
    }
}
