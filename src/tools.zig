
const builtin = @import("builtin");
const pkg = @import("build.zig.zon");
const std = @import("std");
const httpz = @import("httpz");

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

pub fn httpPreflightRequest(request: *std.http.Client.Request) !std.http.Client.Response {
    try request.sendBodiless();

    var buffer: [8 * 1024]u8 = undefined;
    const response = try request.receiveHead(&buffer);

    return switch (response.head.status) {
        .ok => response,
        .not_found => error.NotFound,
        else => error.UpstreamError
    };
}

pub const user_agent = std.fmt.comptimePrint("Mirrors/{s} (mirrors.qsmally.org) Zig/{s}", .{
    pkg.version,
    builtin.zig_version_string });
