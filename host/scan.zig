// Module responsible for scanning source files in the project directory and
// adding them onto the Site object.

const builtin = @import("builtin");
const std = @import("std");
const mime = @import("mime");
const glob = @import("glob.zig");
const fail = @import("fail.zig");
const platform = @import("platform.zig");
const Site = @import("site.zig").Site;
const RocList = @import("roc/list.zig").RocList;

pub fn scan(gpa: std.mem.Allocator, site: *Site) !void {
    var tmp_arena_state = std.heap.ArenaAllocator.init(gpa);
    defer tmp_arena_state.deinit();
    const tmp_arena = tmp_arena_state.allocator();
    var source_iterator = try SourceFileWalker.init(tmp_arena, site);
    defer source_iterator.deinit();
    var unmatched_paths = std.ArrayList([]const u8).init(tmp_arena);
    defer unmatched_paths.deinit();

    const site_arena = site.allocator();
    while (try source_iterator.next()) |path| {
        try addFileToRule(
            tmp_arena,
            site,
            try site_arena.dupe(u8, path),
            &unmatched_paths,
        );
    }

    if (unmatched_paths.items.len > 0) {
        try unmatchedSourceFileError(try unmatched_paths.toOwnedSlice());
    }
}

pub const SourceFileWalker = struct {
    const Self = @This();

    walker: std.fs.Dir.Walker,
    ignore_patterns: []const []const u8,

    pub fn init(allocator: std.mem.Allocator, site: *Site) !Self {
        return Self{
            .walker = try site.source_root.walk(allocator),
            .ignore_patterns = site.ignore_patterns,
        };
    }

    pub fn deinit(self: *Self) void {
        self.walker.deinit();
    }

    pub fn next(self: *Self) !?[]const u8 {
        while (true) {
            const entry = try self.walker.next() orelse return null;

            const ignore = glob.matchAny(self.ignore_patterns, entry.path);
            if (ignore) {
                if (entry.kind == .directory) self.skip();
                continue;
            }

            if (entry.kind != .file) continue;
            return entry.path;
        }
    }

    pub fn skip(self: *Self) void {
        // Reaching into the walker internals here to skip an entire
        // directory, similar to how the walker implementation does
        // this itself in a couple of places. This avoids needing to
        // iterate through potentially large amounts of ignored files,
        // for instance a .git directory.
        var item = self.walker.stack.pop();
        if (self.walker.stack.items.len != 0) {
            item.iter.dir.close();
        }
    }
};

fn addFileToRule(
    tmp_arena: std.mem.Allocator,
    site: *Site,
    source_path: []const u8,
    unmatched_paths: *std.ArrayList([]const u8),
) !void {
    // TODO: detect patterns that are not matched by any file.
    var matched_rules = std.ArrayList(usize).init(tmp_arena);
    defer matched_rules.deinit();

    for (site.rules, 0..) |rule, rule_index| {
        if (!glob.matchAny(rule.patterns, source_path)) continue;

        try matched_rules.append(rule_index);
        try addPath(tmp_arena, site, rule_index, rule.processing, source_path);
    }

    switch (matched_rules.items.len) {
        0 => try unmatched_paths.append(source_path),
        1 => {}, // This is what we expect!
        else => {
            try fail.prettily(
                \\The following file is matched by multiple rules:
                \\
                \\    {s}
                \\
                \\These are the indices of the rules that match:
                \\
                \\    {any}
                \\
                \\
            , .{ source_path, matched_rules.items });
        },
    }
}

pub fn addPath(
    tmp_arena: std.mem.Allocator,
    site: *Site,
    rule_index: usize,
    processing: Site.Processing,
    source_path: []const u8,
) !void {
    const site_arena = site.allocator();
    const output_path = switch (processing) {
        .xml, .none => try std.fmt.allocPrint(site_arena, "/{s}", .{source_path}),
        .markdown => try outputPathForMarkdownFile(site_arena, source_path),
    };

    const frontmatter = switch (processing) {
        .xml, .none => "{}",
        .markdown => blk: {
            const bytes = try site.source_root.readFileAlloc(tmp_arena, source_path, 1024 * 1024);
            if (firstNonWhitespaceByte(bytes) != '{') break :blk "{}";

            const roc_bytes = RocList.fromSlice(u8, bytes, false);
            var meta_len: u64 = undefined;

            // Zig tests can't call out to Roc.
            if (builtin.is_test) {
                meta_len = 0;
            } else {
                platform.roc__getMetadataLengthForHost_1_exposed_generic(&meta_len, &roc_bytes);
            }

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
                , .{source_path});
            }

            break :blk try site_arena.dupe(u8, meta_bytes);
        },
    };

    const extension = std.fs.path.extension(output_path);
    const mime_type = mime.extension_map.get(extension) orelse .@"application/octet-stream";
    const web_path = webPathFromFilePath(output_path);

    const page = Site.Page{
        .rule_index = rule_index,
        .mime_type = mime_type,
        .source_path = source_path,
        .output_path = output_path,
        .web_path = web_path,
        .output_len = null, // We'll know this when we generate the page
        .frontmatter = frontmatter,
    };
    _ = try site.addPage(page);
}

fn unmatchedSourceFileError(unmatched_paths: [][]const u8) !noreturn {
    if (builtin.is_test) return error.PrettyError;

    const stderr = std.io.getStdErr().writer();

    try stderr.print(
        \\Some source files are not matched by any rule.
        \\If you don't mean to include these in your site,
        \\you can ignore them like this:
        \\
        \\    Site.ignore
        \\        [
        \\
    , .{});
    for (unmatched_paths) |path| {
        try stderr.print("            \"{s}\",\n", .{path});
    }
    try stderr.print(
        \\        ]
    , .{});

    return error.PrettyError;
}

fn outputPathForMarkdownFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (!isMarkdown(path)) {
        try fail.prettily("You're asking me to process a file as markdown, but it does not have a markdown file extension: {s}", .{path});
    }
    return std.fmt.allocPrint(
        allocator,
        "/{s}.html",
        .{path[0..(path.len - std.fs.path.extension(path).len)]},
    );
}

test outputPathForMarkdownFile {
    const actual = try outputPathForMarkdownFile(std.testing.allocator, "file.md");
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("/file.html", actual);

    try std.testing.expectError(error.PrettyError, outputPathForMarkdownFile(
        std.testing.allocator,
        "file.txt",
    ));
}

pub fn isMarkdown(path: []const u8) bool {
    const extension = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(extension, ".md") or
        std.ascii.eqlIgnoreCase(extension, ".markdown");
}

test isMarkdown {
    try std.testing.expect(isMarkdown("file.md"));
    try std.testing.expect(isMarkdown("dir/file.MD"));
    try std.testing.expect(isMarkdown("file.MarkDown"));
    try std.testing.expect(!isMarkdown("file.txt"));
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

pub fn webPathFromFilePath(path: []const u8) []const u8 {
    std.debug.assert(path[0] == '/'); // Path's should have a leading slash.
    if (std.mem.eql(u8, "index.html", std.fs.path.basename(path))) {
        return std.fs.path.dirname(path) orelse unreachable;
    } else if (std.mem.eql(u8, ".html", std.fs.path.extension(path))) {
        return path[0..(path.len - ".html".len)];
    } else {
        return path;
    }
}

test webPathFromFilePath {
    try std.testing.expectEqualStrings("/hi/file.css", webPathFromFilePath("/hi/file.css"));
    try std.testing.expectEqualStrings("/hi/file", webPathFromFilePath("/hi/file.html"));
    try std.testing.expectEqualStrings("/hi", webPathFromFilePath("/hi/index.html"));
}
