const std = @import("std");

pub fn glob(full_pattern: []const u8, path: []const u8) bool {
    std.debug.assert(!std.mem.startsWith(u8, path, "/"));
    std.debug.assert(!std.mem.endsWith(u8, path, "/"));

    const pattern = if (full_pattern.len > 0 and full_pattern[0] == '/')
        full_pattern[1..]
    else
        full_pattern;

    var iterator = std.mem.splitAny(u8, pattern, "*");
    var path_index: usize = 0;
    var first = true;

    while (iterator.next()) |segment| {
        while (true) {
            if (path.len - path_index < segment.len) {
                return false;
            }
            if (std.mem.startsWith(u8, path[path_index..], segment)) {
                path_index += segment.len;
                break;
            }
            if (first or path[path_index] == std.fs.path.sep) {
                return false;
            }
            path_index += 1;
        }
        first = false;
    }
    return path_index == 0 or
        path_index == path.len or
        path[path_index] == std.fs.path.sep or
        (pattern.len > 0 and pattern[pattern.len - 1] == '*') or
        (path_index > 0 and path[path_index - 1] == std.fs.path.sep);
}

test glob {
    try std.testing.expect(glob("", "dir/file.txt"));

    // Passes on account of matching the directory containing the file.
    try std.testing.expect(glob("*", "dir/file.txt"));
    try std.testing.expect(glob("dir", "dir/file.txt"));
    try std.testing.expect(glob("dir/", "dir/file.txt"));
    try std.testing.expect(glob("/", "dir/file.txt"));
    try std.testing.expect(glob("/*", "dir/file.txt"));

    // Passes on account of matching the full path.
    try std.testing.expect(glob("dir/file.txt", "dir/file.txt"));
    try std.testing.expect(glob("dir/*", "dir/file.txt"));
    try std.testing.expect(glob("dir/*.txt", "dir/file.txt"));
    try std.testing.expect(glob("dir/file*", "dir/file.txt"));
    try std.testing.expect(glob("*/file.txt", "dir/file.txt"));
    try std.testing.expect(glob("*/*.txt", "dir/file.txt"));
    try std.testing.expect(glob("d*/*.txt", "dir/file.txt"));
    try std.testing.expect(glob("d*r/*.txt", "dir/file.txt"));
    try std.testing.expect(glob("/", "file.txt"));
    try std.testing.expect(glob("*", "file.txt"));
    try std.testing.expect(glob("dir/*/file.txt", "dir/sub/file.txt"));

    // Fail on account of pattern not occuring in the path.
    try std.testing.expect(!glob("nope", "dir/file.txt"));

    // Fail on account of pattern not being anchored on root.
    try std.testing.expect(!glob("file.txt", "dir/file.txt"));
    try std.testing.expect(!glob("file*", "dir/file.txt"));

    // Fail on account of * not spanning /.
    try std.testing.expect(!glob("*.txt", "dir/file.txt"));
    try std.testing.expect(!glob("*/file.txt", "dir/sub/file.txt"));

    // Fail on account of being partial file or directory names.
    try std.testing.expect(!glob(".txt", "file.txt"));
    try std.testing.expect(!glob("di", "dir/file.txt"));
    try std.testing.expect(!glob("dir/file", "dir/file.txt"));
}
