const std = @import("std");
const Site = @import("site.zig").Site;
const fail = @import("fail.zig");
const scan = @import("scan.zig");

// When running the bootstrap script we have to guess which files the user
// might want to be ignored. This is our list of such guesses.
const bootstrap_ignore_patterns = [_][]const u8{
    ".git",
    ".gitignore",
    "README*",
};

pub fn bootstrap(site: *Site, output_root: []const u8) !void {
    try bootstrapRules(site, output_root);
    try generateCodeForRules(site);
}

fn bootstrapRules(site: *Site, output_root: []const u8) !void {
    const allocator = site.arena.allocator();

    var markdown_patterns = std.StringHashMap(void).init(allocator);
    var static_patterns = std.StringHashMap(void).init(allocator);
    var ignore_patterns = std.StringHashMap(void).init(allocator);

    var source_iterator = try scan.SourceFileWalker.init(
        allocator,
        site.source_root,
        site.roc_main,
        output_root,
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
        if (scan.isMarkdown(entry.path)) {
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

test "bootstrapRules" {
    var tmpdir = std.testing.tmpDir(.{ .iterate = true });
    defer tmpdir.cleanup();

    try tmpdir.dir.writeFile(.{ .sub_path = "build.roc", .data = "" });
    const roc_main = try tmpdir.dir.realpathAlloc(std.testing.allocator, "build.roc");
    defer std.testing.allocator.free(roc_main);
    var site = try Site.init(std.testing.allocator, roc_main);
    defer site.deinit();

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

    try bootstrapRules(&site, "output");

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

fn compareStrings(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs).compare(std.math.CompareOperator.lt);
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

fn updateSiteForPatterns(
    site: *Site,
    markdown_patterns: std.hash_map.StringHashMap(void),
    static_patterns: std.hash_map.StringHashMap(void),
    ignore_patterns: std.hash_map.StringHashMap(void),
) !void {
    const allocator = site.arena.allocator();
    var rules = try std.ArrayList(Site.Rule).initCapacity(allocator, 3);
    errdefer rules.deinit();

    if (markdown_patterns.count() > 0) {
        try rules.append(Site.Rule{
            .patterns = try getHashMapKeys(allocator, markdown_patterns),
            .processing = .markdown,
            .pages = std.ArrayList(Site.Page).init(allocator),
            .replaceTags = &[_][]u8{},
        });
    }
    if (static_patterns.count() > 0) {
        try rules.append(Site.Rule{
            .patterns = try getHashMapKeys(allocator, static_patterns),
            .processing = .none,
            .pages = std.ArrayList(Site.Page).init(allocator),
            .replaceTags = &[_][]u8{},
        });
    }
    try rules.append(Site.Rule{
        .patterns = try getHashMapKeys(allocator, ignore_patterns),
        .processing = .ignore,
        .pages = std.ArrayList(Site.Page).init(allocator),
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

fn generateCodeForRules(site: *const Site) !void {
    const file = try site.source_root.openFile(site.roc_main, .{ .mode = .read_write });
    defer file.close();

    // The size of my minimal bootstrap examples is 119 bytes at time of
    // writing. A file might contain some extra whitespace, but if it's much
    // larger than that then there's unexpected content in the file we don't
    // want to overwrite by accident.
    const stat = try file.stat();
    if (stat.size > 200) {
        try fail.prettily(
            \\You're asking me to generate bootstrap code, which involves me
            \\replacing the code in {s}.
            \\
            \\Your {s} contains a bit more code than I expect and I don't
            \\want to accidentally delete anything important.
            \\
            \\If you're sure you want me to bootstrap delete everything from
            \\the {s} file except:
            \\
            \\    app [main] {{ pf: platform "<dont change this part>" }}
            \\
            \\    import pf.Pages
            \\
            \\    main = Pages.bootstrap
            \\
        , .{ site.roc_main, site.roc_main, site.roc_main });
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
    var tmpdir = std.testing.tmpDir(.{});
    defer tmpdir.cleanup();
    try tmpdir.dir.writeFile(.{
        .sub_path = "build.roc",
        .data =
        \\app [main] { pf: platform "some hash here" }
        \\
        \\import pf.Pages
        \\
        \\main = Pages.bootstrap
        ,
    });
    const roc_main = try tmpdir.dir.realpathAlloc(std.testing.allocator, "build.roc");
    defer std.testing.allocator.free(roc_main);
    var site = try Site.init(std.testing.allocator, roc_main);
    defer site.deinit();
    var rules = [_]Site.Rule{
        Site.Rule{
            .processing = .markdown,
            .patterns = ([_][]const u8{ "posts/*.md", "*.md" })[0..],
            .replaceTags = &[_][]const u8{},
            .pages = std.ArrayList(Site.Page).init(std.testing.allocator),
        },
        Site.Rule{
            .processing = .none,
            .patterns = ([_][]const u8{"static"})[0..],
            .replaceTags = &[_][]const u8{},
            .pages = std.ArrayList(Site.Page).init(std.testing.allocator),
        },
        Site.Rule{
            .processing = .ignore,
            .patterns = ([_][]const u8{ ".git", ".gitignore" })[0..],
            .replaceTags = &[_][]const u8{},
            .pages = std.ArrayList(Site.Page).init(std.testing.allocator),
        },
    };
    site.rules = rules[0..];

    try generateCodeForRules(&site);

    const generated = try tmpdir.dir.readFileAlloc(std.testing.allocator, "build.roc", 1024 * 1024);
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
