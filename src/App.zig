
const std = @import("std");
const httpz = @import("httpz");

const App = @This();

io: std.Io,
gpa: std.mem.Allocator,

failure_lock: std.Io.Mutex = .init,
failure_map: std.StringHashMapUnmanaged(i64) = .empty,
in_flight_lock: std.Io.Mutex = .init,
in_flight_map: std.StringHashMapUnmanaged(*InFlightRequest) = .empty,
housekeeping_lock: std.Io.Mutex = .init,
housekeeping_last_sweep: std.Io.Timestamp = .zero,
signature_map: std.StringHashMapUnmanaged([]const u8) = .empty,

pub fn deinit(app: *App) void {
    app.failure_map.deinit(app.gpa);

    var iterator2 = app.in_flight_map.iterator();
    while (iterator2.next()) |entry|
        app.gpa.destroy(entry.value_ptr.*);
    app.in_flight_map.deinit(app.gpa);

    var iterator = app.signature_map.iterator();
    while (iterator.next()) |entry|
        app.gpa.free(entry.value_ptr.*);
    app.signature_map.deinit(app.gpa);
}

pub fn uncaughtError(_: *App, _: *httpz.Request, res: *httpz.Response, err: anyerror) void {
    std.log.err("<<< {}", .{ err });

    res.status = switch (err) {
        error.Canceled => 419,
        error.RateLimit => 429,
        error.NotFound => 404,
        error.UpstreamError => 504,
        error.SignatureVerificationFailed => 503,
        else => 500
    };
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
