const std = @import("std");
const builtin = @import("builtin");
const RocStr = @import("roc/str.zig").RocStr;
const RocList = @import("roc/list.zig").RocList;
const glob = @import("glob.zig");
const xml = @import("xml.zig");
const c = @cImport({
    @cInclude("cmark-gfm.h");
});
comptime {
    // To get tests from xml.zig to be included in runs.
    _ = @import("xml.zig");
}

const Site = struct {
    arena: *std.heap.ArenaAllocator,
    source_root: std.fs.Dir,
    roc_main: []const u8,
    rules: []PageRule,
};

const PageRule = struct {
    patterns: []const []const u8,
    replaceTags: []const []const u8,
    processing: RocProcessing,
    pages: std.ArrayList(Page),
};

const Page = struct {
    source_path: []const u8,
    output_path: []const u8,
    frontmatter: []const u8,
};

const output_root = "output";

extern fn roc__mainForHost_1_exposed_generic(*RocList, *const void) callconv(.C) void;
extern fn roc__getMetadataLengthForHost_1_exposed_generic(*u64, *const RocList) callconv(.C) void;
extern fn roc__runPipelineForHost_1_exposed_generic(*RocList, *const RocPage) callconv(.C) void;

pub fn run() !void {
    var timer = try std.time.Timer.start();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    try runTimed(&gpa);
    const stdout = std.io.getStdOut().writer();
    try stdout.print("Generated site in {d}ms\n", .{timer.read() / 1_000_000});
}

// The platform code uses 'crash' to 'throw' an error to the host in certain
// situations. We can kind of get away with it because compile-time and
// runtime are essentially the same time for this program, and so runtime
// errors have fewer downsides then they might have in other platforms.
//
// To distinguish platform panics from user panics, we prefix platform panics
// with a ridiculous string that hopefully never will attempt to copy.
const panic_prefix = "@$%^&.jayerror*";
pub fn handlePanic(roc_msg: *RocStr, tag_id: u32) void {
    const msg = roc_msg.asSlice();
    if (!std.mem.startsWith(u8, msg, panic_prefix)) {
        failPrettily(
            \\
            \\Roc crashed with the following error:
            \\MSG:{s}
            \\TAG:{d}
            \\
            \\Shutting down
            \\
        , .{ msg, tag_id }) catch {};
        std.process.exit(1);
    }

    const code = msg[panic_prefix.len];
    const details = msg[panic_prefix.len + 2 ..];
    switch (code) {
        '0' => {
            failPrettily(
                \\I ran into an error attempting to decode the following metadata:
                \\
                \\{s}
                \\
            , .{details}) catch {};
            std.process.exit(1);
        },
        '1' => {
            failPrettily(
                \\I ran into an error attempting to decode the following attributes:
                \\
                \\{s}
                \\
            , .{details}) catch {};
            std.process.exit(1);
        },
        else => {
            failPrettily("Unknown panic error code: {d}", .{code}) catch {};
            std.process.exit(1);
        },
    }
}

fn runTimed(gpa: *std.heap.GeneralPurposeAllocator(.{})) !void {
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    // (1) Get the path to the main.roc file that's currently running.
    var args = std.process.args();
    const argv0 = args.next() orelse return error.EmptyArgv;
    const argv0_abs = try std.fs.cwd().realpathAlloc(allocator, argv0);
    const source_root_path = std.fs.path.dirname(argv0_abs) orelse "/";
    const source_root = std.fs.cwd().openDir(source_root_path, .{ .iterate = true }) catch |err| {
        try failPrettily("Cannot access directory containing {s}: '{}'\n", .{ source_root_path, err });
    };

    // (2) Call platform to get page rules.
    var roc_rules = RocList.empty();
    roc__mainForHost_1_exposed_generic(&roc_rules, &void{});
    var site = Site{
        .arena = &arena,
        .source_root = source_root,
        .roc_main = std.fs.path.basename(argv0),
        .rules = try rocListMapToOwnedSlice(
            RocPageRule,
            PageRule,
            rocPagesToPageRule,
            allocator,
            roc_rules,
        ),
    };

    // (3) Scan the project to find all the source files.
    if (site.rules.len == 1 and site.rules[0].processing == .bootstrap) {
        try bootstrapPageRules(&site);
        try generateCodeForRules(&site);
    } else {
        try scanSourceFiles(gpa.allocator(), &site);
    }

    // (4) Generate output files.
    try generateSite(gpa.allocator(), &site, output_root);
}

fn formatOutputPathForRoc(path: []const u8) []const u8 {
    std.debug.assert(path[0] == '/'); // Path's should have a leading slash.
    if (std.mem.eql(u8, std.fs.path.basename(path), "index.html")) {
        return std.fs.path.dirname(path) orelse unreachable;
    } else {
        return path;
    }
}

test formatOutputPathForRoc {
    try std.testing.expectEqualStrings("/hi/file.html", formatOutputPathForRoc("/hi/file.html"));
    try std.testing.expectEqualStrings("/hi", formatOutputPathForRoc("/hi/index.html"));
}

fn generateCodeForRules(site: *const Site) !void {
    const cwd = std.fs.cwd();
    const file = try cwd.openFile(site.roc_main, .{ .mode = .read_write });
    defer file.close();

    // The size of my minimal bootstrap examples is 119 bytes at time of
    // writing. A file might contain some extra whitespace, but if it's much
    // larger than that then there's unexpected content in the file we don't
    // want to overwrite by accident.
    const stat = try file.stat();
    if (stat.size > 200) {
        try failPrettily(
            \\You're asking me to generate bootstrap code, which involves me
            \\replacing the code in main.roc.
            \\
            \\Your main.roc contains a bit more code than I expect and I don't
            \\want to accidentally delete anything important.
            \\
            \\If you're sure you want me to bootstrap delete everything from
            \\the main.roc file except:
            \\
            \\    app [main] {{ pf: platform "<dont change this part>" }}
            \\
            \\    import pf.Pages
            \\
            \\    main = Pages.bootstrap
            \\
        , .{});
    }

    // Find the end of the app header. We could truncate the entire file and
    // regenerate the app-header, but then we'd change the platform hash.
    var reader = file.reader();
    var end_of_app_declaration_offset: u64 = 0;
    while (reader.readByte() catch null) |byte| {
        end_of_app_declaration_offset += 1;
        if (byte == '}') break;
    }

    // We could truncate the file from the app header onwards before starting
    // to write, but the boostrapped code should always be longer than the code
    // we're replacing, or something is wrong. So instead of truncating we
    // instead check the file size before even getting to this point.
    var writer = file.writer();
    try writer.writeAll(
        \\
        \\
        \\import pf.Pages
        \\import pf.Html
        \\
        \\main = [
        \\
    );
    for (site.rules) |rule| {
        switch (rule.processing) {
            .markdown => try writer.writeAll("    markdownFiles,\n"),
            .none => {
                try writer.writeAll(
                    \\    Pages.files [
                );
                for (rule.patterns, 0..) |pattern, index| {
                    try writer.print("\"{s}\"", .{pattern});
                    if (index < rule.patterns.len - 1) {
                        try writer.writeAll(", ");
                    }
                }
                try writer.writeAll(
                    \\],
                    \\
                );
            },
            .ignore => {
                try writer.writeAll(
                    \\    Pages.ignore [
                );
                for (rule.patterns, 0..) |pattern, index| {
                    try writer.print("\"{s}\"", .{pattern});
                    if (index < rule.patterns.len - 1) {
                        try writer.writeAll(", ");
                    }
                }
                try writer.writeAll(
                    \\],
                    \\
                );
            },
            .bootstrap => unreachable,
            .xml => unreachable,
        }
    }
    try writer.writeAll(
        \\]
        \\
        \\
    );
    for (site.rules) |rule| {
        switch (rule.processing) {
            .markdown => {
                try writer.writeAll(
                    \\markdownFiles =
                    \\    Pages.files [
                );
                for (rule.patterns, 0..) |pattern, index| {
                    try writer.print("\"{s}\"", .{pattern});
                    if (index < rule.patterns.len - 1) {
                        try writer.writeAll(", ");
                    }
                }
                try writer.writeAll(
                    \\]
                    \\    |> Pages.fromMarkdown
                    \\    |> Pages.wrapHtml layout
                    \\
                    \\layout = \{ content } ->
                    \\    Html.html {} [
                    \\        Html.head {} [],
                    \\        Html.body {} [content],
                    \\    ]
                    \\
                );
            },
            .none => {},
            .ignore => {},
            .xml => {},
            .bootstrap => unreachable,
        }
    }
}

test generateCodeForRules {
    var tmpdir = std.testing.tmpDir(.{ .iterate = true });
    defer tmpdir.cleanup();
    try tmpdir.dir.writeFile(.{
        .sub_path = "main.roc",
        .data =
        \\app [main] { pf: platform "some hash here" }
        \\
        \\import pf.Pages
        \\
        \\main = Pages.bootstrap
        ,
    });
    var rules = [_]PageRule{
        PageRule{
            .processing = .markdown,
            .patterns = ([_][]const u8{ "posts/*.md", "*.md" })[0..],
            .replaceTags = &[_][]const u8{},
            .pages = std.ArrayList(Page).init(std.testing.allocator),
        },
        PageRule{
            .processing = .none,
            .patterns = ([_][]const u8{"static"})[0..],
            .replaceTags = &[_][]const u8{},
            .pages = std.ArrayList(Page).init(std.testing.allocator),
        },
        PageRule{
            .processing = .ignore,
            .patterns = ([_][]const u8{ ".git", ".gitignore" })[0..],
            .replaceTags = &[_][]const u8{},
            .pages = std.ArrayList(Page).init(std.testing.allocator),
        },
    };
    const roc_main = try tmpdir.dir.realpathAlloc(std.testing.allocator, "main.roc");
    defer std.testing.allocator.free(roc_main);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const site = Site{
        .arena = &arena,
        .source_root = tmpdir.dir,
        .roc_main = roc_main,
        .rules = rules[0..],
    };
    try generateCodeForRules(&site);
    const generated = try tmpdir.dir.readFileAlloc(std.testing.allocator, "main.roc", 1024 * 1024);
    defer std.testing.allocator.free(generated);
    try std.testing.expectEqualStrings(generated,
        \\app [main] { pf: platform "some hash here" }
        \\
        \\import pf.Pages
        \\import pf.Html
        \\
        \\main = [
        \\    markdownFiles,
        \\    Pages.files ["static"],
        \\    Pages.ignore [".git", ".gitignore"],
        \\]
        \\
        \\markdownFiles =
        \\    Pages.files ["posts/*.md", "*.md"]
        \\    |> Pages.fromMarkdown
        \\    |> Pages.wrapHtml layout
        \\
        \\layout = \{ content } ->
        \\    Html.html {} [
        \\        Html.head {} [],
        \\        Html.body {} [content],
        \\    ]
        \\
    );
}

fn bootstrapPageRules(site: *Site) !void {
    const allocator = site.arena.allocator();

    var markdown_patterns = std.StringHashMap(void).init(allocator);
    var static_patterns = std.StringHashMap(void).init(allocator);
    var ignore_patterns = std.StringHashMap(void).init(allocator);

    var source_iterator = try SourceFileWalker.init(
        allocator,
        site.source_root,
        site.roc_main,
        &bootstrap_ignore_patterns,
    );
    defer source_iterator.deinit();
    // TODO: don't just collect patterns, also populate .pages field.
    while (try source_iterator.next()) |entry| {
        if (entry.ignore) {
            try ignore_patterns.put(try allocator.dupe(u8, entry.path), void{});
            continue;
        }

        const pattern = try patternForPath(allocator, entry.path);
        if (isMarkdown(entry.path)) {
            try markdown_patterns.put(pattern, void{});
        } else {
            try static_patterns.put(pattern, void{});
        }
    }
    try updateSiteForPatterns(
        site,
        markdown_patterns,
        static_patterns,
        ignore_patterns,
    );
}

fn updateSiteForPatterns(
    site: *Site,
    markdown_patterns: std.hash_map.StringHashMap(void),
    static_patterns: std.hash_map.StringHashMap(void),
    ignore_patterns: std.hash_map.StringHashMap(void),
) !void {
    const allocator = site.arena.allocator();
    var rules = try std.ArrayList(PageRule).initCapacity(allocator, 3);
    errdefer rules.deinit();

    if (markdown_patterns.count() > 0) {
        try rules.append(PageRule{
            .patterns = try getHashMapKeys(allocator, markdown_patterns),
            .processing = .markdown,
            .pages = std.ArrayList(Page).init(allocator),
            .replaceTags = &[_][]u8{},
        });
    }
    if (static_patterns.count() > 0) {
        try rules.append(PageRule{
            .patterns = try getHashMapKeys(allocator, static_patterns),
            .processing = .none,
            .pages = std.ArrayList(Page).init(allocator),
            .replaceTags = &[_][]u8{},
        });
    }
    try rules.append(PageRule{
        .patterns = try getHashMapKeys(allocator, ignore_patterns),
        .processing = .ignore,
        .pages = std.ArrayList(Page).init(allocator),
        .replaceTags = &[_][]u8{},
    });

    site.rules = try rules.toOwnedSlice();
}

fn getHashMapKeys(
    allocator: std.mem.Allocator,
    map: std.hash_map.StringHashMap(void),
) ![][]const u8 {
    var keys = try allocator.alloc([]const u8, map.count());
    var key_iterator = map.keyIterator();
    var index: usize = 0;
    while (key_iterator.next()) |key| {
        keys[index] = key.*;
        index += 1;
    }
    return keys;
}

fn patternForPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const extension = std.fs.path.extension(path);
    return if (std.fs.path.dirname(path)) |dirname|
        try std.fmt.allocPrint(
            allocator,
            "{s}/*{s}",
            .{ dirname, extension },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "*{s}",
            .{extension},
        );
}

fn compareStrings(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs).compare(std.math.CompareOperator.lt);
}

test "bootstrapPageRules" {
    var tmpdir = std.testing.tmpDir(.{ .iterate = true });
    defer tmpdir.cleanup();

    try tmpdir.dir.makeDir("markdown_only");
    try tmpdir.dir.makeDir("static_only");
    try tmpdir.dir.makeDir("mixed");

    try tmpdir.dir.writeFile(.{ .sub_path = "markdown_only/one.md", .data = "" });
    try tmpdir.dir.writeFile(.{ .sub_path = "markdown_only/two.md", .data = "" });
    try tmpdir.dir.writeFile(.{ .sub_path = "static_only/main.css", .data = "" });
    try tmpdir.dir.writeFile(.{ .sub_path = "static_only/logo.png", .data = "" });
    try tmpdir.dir.writeFile(.{ .sub_path = "mixed/three.md", .data = "" });
    try tmpdir.dir.writeFile(.{ .sub_path = "mixed/rss.xml", .data = "" });
    try tmpdir.dir.writeFile(.{ .sub_path = "index.md", .data = "" });
    try tmpdir.dir.writeFile(.{ .sub_path = ".gitignore", .data = "" });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var site = Site{
        .arena = &arena,
        .source_root = tmpdir.dir,
        .roc_main = "main.roc",
        .rules = &.{},
    };

    try bootstrapPageRules(&site);

    try std.testing.expectEqual(3, site.rules.len);

    try std.testing.expectEqual(.markdown, site.rules[0].processing);
    try std.testing.expectEqual(3, site.rules[0].patterns.len);
    const markdown_patterns = try std.testing.allocator.dupe([]const u8, site.rules[0].patterns);
    defer std.testing.allocator.free(markdown_patterns);
    std.sort.insertion([]const u8, markdown_patterns, {}, compareStrings);
    try std.testing.expectEqualStrings("*.md", markdown_patterns[0]);
    try std.testing.expectEqualStrings("markdown_only/*.md", markdown_patterns[1]);
    try std.testing.expectEqualStrings("mixed/*.md", markdown_patterns[2]);

    try std.testing.expectEqual(.none, site.rules[1].processing);
    try std.testing.expectEqual(3, site.rules[1].patterns.len);
    const static_patterns = try std.testing.allocator.dupe([]const u8, site.rules[1].patterns);
    defer std.testing.allocator.free(static_patterns);
    std.sort.insertion([]const u8, static_patterns, {}, compareStrings);
    try std.testing.expectEqualStrings("mixed/*.xml", static_patterns[0]);
    try std.testing.expectEqualStrings("static_only/*.css", static_patterns[1]);
    try std.testing.expectEqualStrings("static_only/*.png", static_patterns[2]);

    try std.testing.expectEqual(.ignore, site.rules[2].processing);
    try std.testing.expectEqual(1, site.rules[2].patterns.len);
    try std.testing.expectEqualStrings(".gitignore", site.rules[2].patterns[0]);
}

const SourceFileWalker = struct {
    const Self = @This();

    const Entry = struct {
        path: []const u8,
        ignore: bool,
    };

    walker: std.fs.Dir.Walker,
    explicit_ignores: []const []const u8,
    implicit_ignores: []const []const u8,

    fn init(
        allocator: std.mem.Allocator,
        source_root: std.fs.Dir,
        roc_main: []const u8,
        explicit_ignores: []const []const u8,
    ) !Self {
        // The Roc file that starts this script as well as anything we generate
        // should be ignored implicitly, i.e. the user should not need to
        // specify these.
        var implicit_ignores = try allocator.alloc([]const u8, 3);
        implicit_ignores[0] = output_root;
        implicit_ignores[1] = roc_main;
        implicit_ignores[2] = std.fs.path.stem(roc_main);

        return Self{
            .walker = try source_root.walk(allocator),
            .explicit_ignores = explicit_ignores,
            .implicit_ignores = implicit_ignores,
        };
    }

    fn deinit(self: *Self) void {
        self.walker.deinit();
    }

    fn next(self: *Self) !?Entry {
        while (true) {
            const entry = try self.walker.next() orelse return null;
            const ignore_implicitly = glob.matchAny(self.implicit_ignores, entry.path);
            const ignore_explicitly = glob.matchAny(self.explicit_ignores, entry.path);
            const ignore = ignore_implicitly or ignore_explicitly;

            if (ignore and entry.kind == .directory) {
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

            if (entry.kind != .file) continue;

            // Here's where the difference between implicit and explicit
            // ignores becomes material. Implicit ignores we don't even let
            // the code know about - we just pretend these files don't exist.
            if (ignore_implicitly) continue;

            return Entry{
                .path = entry.path,
                .ignore = ignore,
            };
        }
    }
};

fn scanSourceFiles(gpa_allocator: std.mem.Allocator, site: *Site) !void {
    const allocator = site.arena.allocator();
    const explicit_ignores = try getRuleIgnorePatterns(allocator, site.rules);
    var source_iterator = try SourceFileWalker.init(
        allocator,
        site.source_root,
        site.roc_main,
        explicit_ignores,
    );
    defer source_iterator.deinit();
    var unmatched_paths = std.ArrayList([]const u8).init(allocator);
    defer unmatched_paths.deinit();
    while (try source_iterator.next()) |entry| {
        if (entry.ignore) {
            continue;
        } else {
            const path = try allocator.dupe(u8, entry.path);
            try addFileToRule(gpa_allocator, site, path, &unmatched_paths);
        }
    }

    if (unmatched_paths.items.len > 0) {
        try unmatchedSourceFileError(try unmatched_paths.toOwnedSlice());
    }
}

fn addFileToRule(
    gpa_allocator: std.mem.Allocator,
    site: *Site,
    source_path: []const u8,
    unmatched_paths: *std.ArrayList([]const u8),
) !void {
    const allocator = site.arena.allocator();

    // TODO: detect patterns that are not matched by any file.
    var matched_rules = std.ArrayList(usize).init(allocator);
    defer matched_rules.deinit();

    for (site.rules, 0..) |rule, index| {
        if (!glob.matchAny(rule.patterns, source_path)) continue;

        try matched_rules.append(index);
        const output_path = switch (rule.processing) {
            .ignore => return error.UnexpectedlyAskedToAddIgnoredFile,
            .bootstrap => return error.UnexpectedlyAskedToAddFileForBootstrapRule,
            .xml, .none => try std.fmt.allocPrint(allocator, "/{s}", .{source_path}),
            .markdown => try outputPathForMarkdownFile(allocator, source_path),
        };

        const frontmatter = switch (rule.processing) {
            .ignore => return error.UnexpectedlyAskedToAddIgnoredFile,
            .bootstrap => return error.UnexpectedlyAskedToAddFileForBootstrapRule,
            .xml, .none => "{}",
            .markdown => blk: {
                const bytes = try site.source_root.readFileAlloc(gpa_allocator, source_path, 1024 * 1024);
                defer gpa_allocator.free(bytes);
                if (firstNonWhitespaceByte(bytes) != '{') break :blk "{}";

                const roc_bytes = RocList.fromSlice(u8, bytes, false);
                var meta_len: u64 = undefined;
                roc__getMetadataLengthForHost_1_exposed_generic(&meta_len, &roc_bytes);

                // Markdown headers start with #, just like Roc comments. RVN
                // supports comments, so if there's a header below the page
                // frontmatter it is parsed as well. We'll peel these off.
                const meta_bytes = dropTrailingHeaderLines(bytes[0..meta_len]);

                if (meta_bytes.len == 0) {
                    try failPrettily(
                        \\I ran into an error attempting to decode the metadata
                        \\at the start of this file:
                        \\
                        \\    {s}
                        \\
                    , .{source_path});
                }

                break :blk try allocator.dupe(u8, meta_bytes);
            },
        };

        try site.rules[index].pages.append(Page{
            .source_path = source_path,
            .output_path = output_path,
            .frontmatter = frontmatter,
        });
    }

    switch (matched_rules.items.len) {
        0 => try unmatched_paths.append(source_path),
        1 => {}, // This is what we expect!
        else => {
            try failPrettily(
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

// Read ignore patterns out of the page rules read from code.
fn getRuleIgnorePatterns(
    allocator: std.mem.Allocator,
    rules: []const PageRule,
) ![]const []const u8 {
    var ignore_patterns = std.ArrayList([]const u8).init(allocator);
    for (rules) |rule| {
        if (rule.processing == .ignore) {
            try ignore_patterns.appendSlice(rule.patterns);
        }
    }
    return ignore_patterns.toOwnedSlice();
}

// When running the bootstrap script we have to guess which files the user
// might want to be ignored. This is our list of such guesses.
const bootstrap_ignore_patterns = [_][]const u8{
    ".git",
    ".gitignore",
    "README*",
};

const RocPageRule = extern struct {
    patterns: RocList,
    replaceTags: RocList,
    processing: RocProcessing,
};

const RocProcessing = enum(u8) {
    bootstrap = 0,
    ignore = 1,
    markdown = 2,
    none = 3,
    xml = 4,
};

const RocPage = extern struct {
    meta: RocList,
    path: RocStr,
    tags: RocList,
    len: u32,
    ruleIndex: u32,
};

const RocTag = extern struct {
    attributes: RocList,
    index: u32,
    innerEnd: u32,
    innerStart: u32,
    outerEnd: u32,
    outerStart: u32,
};

const Slice = union(enum) {
    from_source: u64,
    roc_generated: []const u8,
};

const RocSlice = extern struct {
    payload: RocSlicePayload,
    tag: RocSliceTag,
};

const RocSlicePayload = extern union {
    from_source: RocSourceLoc,
    roc_generated: RocList,
};

const RocSliceTag = enum(u8) {
    from_source = 0,
    roc_generated = 1,
};

const RocSourceLoc = extern struct {
    end: u32,
    start: u32,
};

fn rocPagesToPageRule(allocator: std.mem.Allocator, pages: RocPageRule) !PageRule {
    return .{
        .patterns = try rocListMapToOwnedSlice(
            RocStr,
            []const u8,
            fromRocStr,
            allocator,
            pages.patterns,
        ),
        .replaceTags = try rocListMapToOwnedSlice(
            RocStr,
            []const u8,
            fromRocStr,
            allocator,
            pages.replaceTags,
        ),
        .processing = pages.processing,
        .pages = std.ArrayList(Page).init(allocator),
    };
}

fn fromRocStr(allocator: std.mem.Allocator, roc_pattern: RocStr) ![]const u8 {
    return try allocator.dupe(u8, roc_pattern.asSlice());
}

fn fromRocSlice(allocator: std.mem.Allocator, roc_content: RocSlice) !Slice {
    return switch (roc_content.tag) {
        .RocFromSource => .{ .from_source = roc_content.payload.from_source },
        .RocSlice => {
            const slice = try rocListCopyToOwnedSlice(
                u8,
                allocator,
                roc_content.payload.slice,
            );
            return .{ .slice = slice };
        },
    };
}

fn RocListIterator(comptime T: type) type {
    return struct {
        const Self = @This();

        elements: ?[*]T,
        len: usize,
        index: usize,

        fn init(list: RocList) Self {
            return Self{
                .elements = list.elements(T),
                .len = list.len(),
                .index = 0,
            };
        }

        fn next(self: *Self) ?T {
            if (self.index < self.len) {
                const elem = self.elements.?[self.index];
                self.index += 1;
                return elem;
            } else {
                return null;
            }
        }
    };
}

fn rocListMapToOwnedSlice(
    comptime T: type,
    comptime O: type,
    comptime map: fn (allocator: std.mem.Allocator, elem: T) anyerror!O,
    allocator: std.mem.Allocator,
    list: RocList,
) ![]O {
    const len = list.len();
    if (len == 0) return allocator.alloc(O, 0);
    const elements = list.elements(T) orelse return error.RocListUnexpectedlyEmpty;
    const slice = try allocator.alloc(O, len);
    for (elements, 0..len) |element, index| {
        slice[index] = try map(allocator, element);
    }
    return slice;
}

fn rocListCopyToOwnedSlice(
    comptime T: type,
    allocator: std.mem.Allocator,
    list: RocList,
) ![]T {
    const len = list.len();
    if (len == 0) return allocator.alloc(T, 0);
    const elements = list.elements(T) orelse return error.RocListUnexpectedlyEmpty;
    const slice = try allocator.alloc(T, len);
    for (elements, 0..len) |element, index| {
        slice[index] = element;
    }
    return slice;
}

fn outputPathForMarkdownFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (!isMarkdown(path)) {
        try failPrettily("You're asking me to process a file as markdown, but it does not have a markdown file extension: {s}", .{path});
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

fn isMarkdown(path: []const u8) bool {
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

// For use in situations where we want to show a pretty helpful error.
// 'pretty' is relative, much work to do here to really live up to that.
pub fn failPrettily(comptime format: []const u8, args: anytype) !noreturn {
    if (!builtin.is_test) {
        const stderr = std.io.getStdErr().writer();
        try stderr.print(format, args);
    }
    return error.PrettyError;
}

// For use in theoretically-possible-but-unlikely scenarios that we don't want
// to write dedicated error messages for.
pub fn failCrudely(err: anyerror) noreturn {
    // Make sure we only print if we didn't already show a pretty error.
    if (err != error.PrettyError) {
        failPrettily("Error: {}", .{err}) catch {};
    }
    std.process.exit(1);
}

fn generateSite(
    gpa_allocator: std.mem.Allocator,
    site: *const Site,
    output_dir_path: []const u8,
) !void {
    // Clear output directory if it already exists.
    site.source_root.deleteTree(output_dir_path) catch |err| {
        if (err != error.NotDir) {
            return err;
        }
    };
    try site.source_root.makeDir(output_dir_path);
    var output_dir = try site.source_root.openDir(output_dir_path, .{});
    defer output_dir.close();

    var arena = std.heap.ArenaAllocator.init(gpa_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for (site.rules, 0..) |rule, rule_index| {
        for (rule.pages.items) |page| {
            if (std.fs.path.dirname(page.output_path[1..])) |dir| try output_dir.makePath(dir);
            try generateSitePath(
                allocator,
                site.source_root,
                rule,
                rule_index,
                page,
                output_dir,
            );
            _ = arena.reset(.retain_capacity);
        }
    }
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

fn generateSitePath(
    allocator: std.mem.Allocator,
    source_root: std.fs.Dir,
    rule: PageRule,
    rule_index: usize,
    page: Page,
    output_dir: std.fs.Dir,
) !void {
    const output = try output_dir.createFile(page.output_path[1..], .{ .truncate = true, .exclusive = true });
    defer output.close();
    var writer = output.writer();

    switch (rule.processing) {
        .ignore => return error.UnexpectedlyAskedToGenerateOutputForIgnoredFile,
        .bootstrap => return error.UnexpectedlyAskedToGenerateOutputForBootstrapRule,
        .none => {
            // I'd like to use the below, but get the following error when I do:
            //     hidden symbol `__dso_handle' isn't defined
            // try state.source_root.copyFile(source_path, output_dir, output_path, .{});

            const buffer = try allocator.alloc(u8, 1024);
            defer allocator.free(buffer);
            var fifo = std.fifo.LinearFifo(u8, .Slice).init(buffer);
            defer fifo.deinit();

            const source = try source_root.openFile(page.source_path, .{});
            defer source.close();
            try fifo.pump(source.reader(), output.writer());
        },
        .xml => {
            // TODO: figure out what to do with files larger than this.
            const source = try source_root.readFileAlloc(allocator, page.source_path, 1024 * 1024);
            defer allocator.free(source);
            const contents = try runPageTransforms(allocator, source, rule, rule_index, page);
            try writeRocContents(contents, source, &writer);
        },
        .markdown => {
            // TODO: figure out what to do with files larger than this.
            const raw_source = try source_root.readFileAlloc(
                allocator,
                page.source_path,
                1024 * 1024,
            );
            defer allocator.free(raw_source);
            const markdown = raw_source[page.frontmatter.len..];
            defer allocator.free(markdown);
            const html = c.cmark_markdown_to_html(
                @ptrCast(markdown),
                markdown.len,
                c.CMARK_OPT_DEFAULT | c.CMARK_OPT_UNSAFE,
            ) orelse return error.OutOfMemory;
            defer std.c.free(html);
            const source = std.mem.span(html);
            const contents = try runPageTransforms(
                allocator,
                source,
                rule,
                rule_index,
                page,
            );
            try writeRocContents(contents, source, &writer);
        },
    }
}

fn runPageTransforms(
    allocator: std.mem.Allocator,
    source: []const u8,
    rule: PageRule,
    rule_index: usize,
    page: Page,
) !RocList {
    const tags = try xml.parse(allocator, source, rule.replaceTags);
    defer allocator.free(tags);
    var roc_tags = std.ArrayList(RocTag).init(allocator);
    defer roc_tags.deinit();
    for (tags) |tag| {
        try roc_tags.append(RocTag{
            .attributes = RocList.fromSlice(u8, tag.attributes, false),
            .outerStart = @as(u32, @intCast(tag.outer_start)),
            .outerEnd = @as(u32, @intCast(tag.outer_end)),
            .innerStart = @as(u32, @intCast(tag.inner_start)),
            .innerEnd = @as(u32, @intCast(tag.inner_end)),
            .index = @as(u32, @intCast(tag.index)),
        });
    }
    const roc_page = RocPage{
        .meta = RocList.fromSlice(u8, page.frontmatter, false),
        .path = RocStr.fromSlice(page.output_path),
        .ruleIndex = @as(u32, @intCast(rule_index)),
        .tags = RocList.fromSlice(RocTag, try roc_tags.toOwnedSlice(), true),
        .len = @as(u32, @intCast(source.len)),
    };
    var contents = RocList.empty();
    roc__runPipelineForHost_1_exposed_generic(&contents, &roc_page);
    return contents;
}

fn writeRocContents(
    contents: RocList,
    source: []const u8,
    writer: *std.fs.File.Writer,
) !void {
    var roc_xml_iterator = RocListIterator(RocSlice).init(contents);
    while (roc_xml_iterator.next()) |roc_slice| {
        switch (roc_slice.tag) {
            .from_source => {
                const slice = roc_slice.payload.from_source;
                try writer.writeAll(source[slice.start..slice.end]);
            },
            .roc_generated => {
                const roc_slice_list = roc_slice.payload.roc_generated;
                const len = roc_slice_list.len();
                if (len == 0) continue;
                const slice = roc_slice_list.elements(u8) orelse return error.RocListUnexpectedEmpty;
                try writer.writeAll(slice[0..len]);
            },
        }
    }
}
