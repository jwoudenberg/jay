// Module responsible for scanning source files in the project directory and
// adding them onto the Site object.

const builtin = @import("builtin");
const std = @import("std");
const mime = @import("mime");
const glob = @import("glob.zig");
const fail = @import("fail.zig");
const WorkQueue = @import("work.zig").WorkQueue;
const platform = @import("platform.zig").platform;
const Site = @import("site.zig").Site;
const RocList = @import("roc/list.zig").RocList;
const Path = @import("path.zig").Path;
const Watcher = @import("watch.zig").Watcher(Path, Path.bytes);

pub fn scanDir(
    work: *WorkQueue,
    paths: *Path.Registry,
    site: *Site,
    watcher: *Watcher,
    source_root: std.fs.Dir,
    dir_path: Path,
) !void {
    try watcher.watchDir(dir_path);
    const dir = if (dir_path.bytes().len == 0) blk: {
        break :blk source_root;
    } else blk: {
        break :blk try source_root.openDir(dir_path.bytes(), .{ .iterate = true });
    };
    var iterator = dir.iterateAssumeFirstIteration();
    while (true) {
        const entry = try iterator.next() orelse break;
        var buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const path_bytes = if (dir_path.bytes().len == 0) blk: {
            break :blk entry.name;
        } else blk: {
            break :blk try std.fmt.bufPrint(&buffer, "{s}/{s}", .{ dir_path.bytes(), entry.name });
        };
        if (glob.matchAny(site.ignore_patterns, path_bytes)) continue;

        const path = try paths.intern(path_bytes);
        switch (entry.kind) {
            .file => {
                try work.push(.{ .scan_file = path });
            },
            .directory => {
                try work.push(.{ .scan_dir = path });
            },
            .block_device,
            .character_device,
            .named_pipe,
            .sym_link,
            .unix_domain_socket,
            .whiteout,
            .door,
            .event_port,
            .unknown,
            => {
                try fail.prettily(
                    \\Encountered a path of type {s}:
                    \\
                    \\    {s}
                    \\
                    \\I don't support generating pages from this type of file!
                    \\
                    \\Tip: Remove the path from the source directory.
                , .{ @tagName(entry.kind), path.bytes() });
            },
        }
    }
}

test scanDir {
    var tmpdir = std.testing.tmpDir(.{ .iterate = true });
    defer tmpdir.cleanup();

    var paths = Path.Registry.init(std.testing.allocator);
    defer paths.deinit();

    var work = WorkQueue.init(std.testing.allocator);
    defer work.deinit();

    var site = try Site.init(std.testing.allocator, "build.roc", "output", &paths);
    defer site.deinit();

    var watcher = try Watcher.init(std.testing.allocator, tmpdir.dir);
    defer watcher.deinit();

    try tmpdir.dir.writeFile(.{ .sub_path = "c", .data = "" });
    try tmpdir.dir.makeDir("b");
    try tmpdir.dir.writeFile(.{ .sub_path = "a", .data = "" });

    try scanDir(
        &work,
        &paths,
        &site,
        &watcher,
        tmpdir.dir,
        try paths.intern(""),
    );

    try std.testing.expectEqualStrings("b", work.pop().?.scan_dir.bytes());
    try std.testing.expectEqualStrings("c", work.pop().?.scan_file.bytes());
    try std.testing.expectEqualStrings("a", work.pop().?.scan_file.bytes());
    try std.testing.expectEqual(null, work.pop());
}

pub fn scanFile(
    arena: std.mem.Allocator,
    work: *WorkQueue,
    site: *Site,
    source_root: std.fs.Dir,
    source_path: Path,
) !void {
    const frontmatter = if (Site.isMarkdown(source_path.bytes()))
        "{}"
    else
        try readFrontmatter(arena, source_root, source_path);
    try site.addPage(source_path, frontmatter);
    try work.push(.{ .generate_file = source_path });
}

fn readFrontmatter(
    arena: std.mem.Allocator,
    source_root: std.fs.Dir,
    source_path: Path,
) ![]const u8 {
    const bytes = try source_root.readFileAlloc(arena, source_path.bytes(), 1024 * 1024);
    if (firstNonWhitespaceByte(bytes) != '{') return "{}";

    var meta_len: u64 = undefined;
    meta_len = platform.getMetadataLength(bytes);

    // Markdown headers start with #, just like Roc comments. RVN
    // supports comments, so if there's a header below the page
    // frontmatter it is parsed as well. We'll peel these off.
    const meta_bytes = dropTrailingHeaderLines(bytes[0..meta_len]);

    if (meta_bytes.len == 0) {
        try fail.prettily(
            \\I ran into an error attempting to decode the metadata
            \\at the start of this file:
            \\
            \\    {s}
            \\
        , .{source_path.bytes()});
    }

    return meta_bytes;
}

test readFrontmatter {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmpdir = std.testing.tmpDir(.{ .iterate = true });
    defer tmpdir.cleanup();

    var paths = Path.Registry.init(std.testing.allocator);
    defer paths.deinit();

    // This test makes use of the test platform defined in platform.zig!

    try tmpdir.dir.writeFile(.{ .sub_path = "file1.txt", .data = "no frontmatter" });
    try std.testing.expectEqualStrings(
        "{}",
        try readFrontmatter(arena, tmpdir.dir, try paths.intern("file1.txt")),
    );

    try tmpdir.dir.writeFile(.{ .sub_path = "file2.txt", .data = "{ hi: 3 }\n# header \x14" });
    try std.testing.expectEqualStrings(
        "{ hi: 3 }",
        try readFrontmatter(arena, tmpdir.dir, try paths.intern("file2.txt")),
    );

    try tmpdir.dir.writeFile(.{ .sub_path = "file3.txt", .data = "{ \x00" });
    try std.testing.expectEqual(
        error.PrettyError,
        readFrontmatter(arena, tmpdir.dir, try paths.intern("file3.txt")),
    );
}

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
