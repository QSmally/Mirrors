
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

pub fn write(io: std.Io, path: []const u8, content: []const u8) !void {
    const file = try cwd.createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content);
}

pub const cwd = std.Io.Dir.cwd();
