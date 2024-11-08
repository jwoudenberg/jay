const std = @import("std");

pub fn formatPathForPlatform(path: []const u8) []const u8 {
    std.debug.assert(path[0] == '/'); // Path's should have a leading slash.
    if (std.mem.eql(u8, std.fs.path.basename(path), "index.html")) {
        return std.fs.path.dirname(path) orelse unreachable;
    } else {
        return path;
    }
}

test formatPathForPlatform {
    try std.testing.expectEqualStrings("/hi/file.html", formatPathForPlatform("/hi/file.html"));
    try std.testing.expectEqualStrings("/hi", formatPathForPlatform("/hi/index.html"));
}
