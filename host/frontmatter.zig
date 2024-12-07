// Struct for storing the frontmatters fromt the various markdown source files
// we scanned.

const std = @import("std");
const Str = @import("str.zig").Str;
const platform = @import("platform.zig").platform;
const fail = @import("fail.zig");

pub const Frontmatters = struct {
    arena_state: std.heap.ArenaAllocator,
    frontmatters: std.AutoHashMapUnmanaged(usize, []const u8),

    pub fn init(gpa: std.mem.Allocator) Frontmatters {
        const arena_state = std.heap.ArenaAllocator.init(gpa);
        return .{
            .arena_state = arena_state,
            .frontmatters = std.AutoHashMapUnmanaged(usize, []const u8){},
        };
    }

    pub fn deinit(self: *Frontmatters) void {
        const gpa = self.arena_state.child_allocator;
        var iterator = self.frontmatters.valueIterator();
        while (iterator.next()) |frontmatter| gpa.free(frontmatter.*);
        self.frontmatters.deinit(gpa);
        self.arena_state.deinit();
    }

    pub fn get(
        self: *const Frontmatters,
        source_path: Str,
    ) ?[]const u8 {
        return self.frontmatters.get(source_path.index());
    }

    pub fn read(
        self: *Frontmatters,
        source_root: std.fs.Dir,
        source_path: Str,
    ) ![]const u8 {
        const gpa = self.arena_state.child_allocator;
        _ = self.arena_state.reset(.{ .retain_with_limit = 1024 * 1024 });
        const arena = self.arena_state.allocator();

        const bytes = try source_root.readFileAlloc(arena, source_path.bytes(), 1024 * 1024);
        var meta_bytes: []const u8 = "{}";
        if (firstNonWhitespaceByte(bytes) == '{') {
            var meta_len: u64 = undefined;
            meta_len = platform.getMetadataLength(bytes);

            // Markdown headers start with #, just like Roc comments. RVN
            // supports comments, so if there's a header below the page
            // frontmatter it is parsed as well. We'll peel these off.
            meta_bytes = dropTrailingHeaderLines(bytes[0..meta_len]);
        }

        if (meta_bytes.len == 0) {
            try fail.prettily(
                \\I ran into an error attempting to decode the metadata
                \\at the start of this file:
                \\
                \\    {s}
                \\
            , .{source_path.bytes()});
        }

        const get_or_put = try self.frontmatters.getOrPut(gpa, source_path.index());
        if (get_or_put.found_existing) {
            if (!std.mem.eql(u8, get_or_put.value_ptr.*, meta_bytes)) {
                gpa.free(get_or_put.value_ptr.*);
                get_or_put.value_ptr.* = try gpa.dupe(u8, meta_bytes);
            }
            return get_or_put.value_ptr.*;
        } else {
            get_or_put.value_ptr.* = try gpa.dupe(u8, meta_bytes);
            return get_or_put.value_ptr.*;
        }
    }

    test read {
        var frontmatters = Frontmatters.init(std.testing.allocator);
        defer frontmatters.deinit();

        var tmpdir = std.testing.tmpDir(.{ .iterate = true });
        defer tmpdir.cleanup();

        var strs = Str.Registry.init(std.testing.allocator);
        defer strs.deinit();

        // This test makes use of the test platform defined in platform.zig!

        try tmpdir.dir.writeFile(.{ .sub_path = "file1.txt", .data = "no frontmatter" });
        try std.testing.expectEqualStrings(
            "{}",
            (try frontmatters.read(tmpdir.dir, try strs.intern("file1.txt"))),
        );

        try tmpdir.dir.writeFile(.{ .sub_path = "file2.txt", .data = "{ hi: 3 }\n# header \x14" });
        try std.testing.expectEqualStrings(
            "{ hi: 3 }",
            (try frontmatters.read(tmpdir.dir, try strs.intern("file2.txt"))),
        );

        try tmpdir.dir.writeFile(.{ .sub_path = "file3.txt", .data = "{ \x00" });
        try std.testing.expectEqual(
            error.PrettyError,
            frontmatters.read(tmpdir.dir, try strs.intern("file3.txt")),
        );
    }
};

fn firstNonWhitespaceByte(bytes: []const u8) ?u8 {
    if (std.mem.indexOfNone(u8, bytes, &std.ascii.whitespace)) |index| {
        return bytes[index];
    } else {
        return null;
    }
}

test firstNonWhitespaceByte {
    try std.testing.expectEqual('x', firstNonWhitespaceByte("x"));
    try std.testing.expectEqual('x', firstNonWhitespaceByte(" x"));
    try std.testing.expectEqual('x', firstNonWhitespaceByte("\tx"));
    try std.testing.expectEqual('x', firstNonWhitespaceByte("\nx"));
    try std.testing.expectEqual('x', firstNonWhitespaceByte("x y"));
    try std.testing.expectEqual('x', firstNonWhitespaceByte("\n \tx"));
    try std.testing.expectEqual('x', firstNonWhitespaceByte("xy"));
    try std.testing.expectEqual(null, firstNonWhitespaceByte(" "));
    try std.testing.expectEqual(null, firstNonWhitespaceByte(""));
}

fn dropTrailingHeaderLines(bytes: []const u8) []const u8 {
    if (bytes.len == 0) return bytes;

    var end = bytes.len;
    var ahead_of_header = false;
    var whitespace_only = true;
    for (1..1 + bytes.len) |index| {
        switch (bytes[bytes.len - index]) {
            '\n' => {
                if (!(ahead_of_header or whitespace_only)) break;
                end = bytes.len - index;
                ahead_of_header = false;
                whitespace_only = true;
            },
            '#' => {
                ahead_of_header = true;
            },
            else => |byte| {
                if (std.mem.indexOfScalar(u8, &std.ascii.whitespace, byte)) |_| continue;
                if (ahead_of_header) break;
                whitespace_only = false;
            },
        }
    }
    return bytes[0..end];
}

test dropTrailingHeaderLines {
    try std.testing.expectEqualStrings("{\n}", dropTrailingHeaderLines("{\n}\n"));
    try std.testing.expectEqualStrings("{\n}", dropTrailingHeaderLines("{\n}\n#foo"));
    try std.testing.expectEqualStrings("{\n}", dropTrailingHeaderLines("{\n}\n# foo"));
    try std.testing.expectEqualStrings("{\n}", dropTrailingHeaderLines("{\n}\n#\tfoo"));
    try std.testing.expectEqualStrings("{\n}", dropTrailingHeaderLines("{\n}\n# foo"));
    try std.testing.expectEqualStrings("{\n}", dropTrailingHeaderLines("{\n}\n##foo\n"));
    try std.testing.expectEqualStrings("{\n}", dropTrailingHeaderLines("{\n}\n\n#foo"));
    try std.testing.expectEqualStrings("{\n}", dropTrailingHeaderLines("{\n}\n#foo\n"));
    try std.testing.expectEqualStrings("{\n}", dropTrailingHeaderLines("{\n}\n#foo\n##bar"));

    // This is not a markdown header but a trailing comment
    try std.testing.expectEqualStrings("{\n} #foo", dropTrailingHeaderLines("{\n} #foo"));
    try std.testing.expectEqualStrings("{\n}\t#foo", dropTrailingHeaderLines("{\n}\t#foo"));
    try std.testing.expectEqualStrings("{\n}#foo", dropTrailingHeaderLines("{\n}#foo\n#bar"));
}
