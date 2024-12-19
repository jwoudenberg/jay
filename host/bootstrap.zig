// Module responsible for generating an initial set of build rules for a
// project, based on the markdown, html, and other source files present in
// the project directory.

const std = @import("std");
const Site = @import("site.zig").Site;
const TestSite = @import("site.zig").TestSite;
const fail = @import("fail.zig");
const SourceDirIterator = @import("scan.zig").SourceDirIterator;
const Watcher = @import("watch.zig").Watcher(Str, Str.bytes);
const Str = @import("str.zig").Str;

pub fn bootstrap(
    gpa: std.mem.Allocator,
    site: *Site,
) !void {
    var source_root = try site.openSourceRoot(.{ .iterate = true });
    defer source_root.close();

    try bootstrapRules(gpa, site, source_root);
    try generateCodeForRules(site, source_root);
}

fn bootstrapRules(
    gpa: std.mem.Allocator,
    site: *Site,
    source_root: std.fs.Dir,
) !void {
    const site_arena = site.allocator();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const tmp_arena = arena_state.allocator();

    var ignore_patterns = std.ArrayList(Str).init(tmp_arena);
    try ignore_patterns.appendSlice(site.ignore_patterns);
    var markdown_patterns = std.ArrayList(Str).init(tmp_arena);
    var static_patterns = std.ArrayList(Str).init(tmp_arena);

    site.rules = try site_arena.dupe(Site.Rule, &.{
        Site.Rule{
            .processing = .none,
            .patterns = static_patterns.items,
            .replace_tags = &.{},
        },
        Site.Rule{
            .processing = .markdown,
            .patterns = markdown_patterns.items,
            .replace_tags = &.{},
        },
    });

    // When running the bootstrap script we have to guess which files the user
    // might want to be ignored. This is our list of such guesses.
    const bootstrap_ignore_patterns = [_]Str{
        try site.strs.intern(".*"),
        try site.strs.intern("flake.*"),
        try site.strs.intern("README*"),
        try site.strs.intern("LICENSE*"),
    };

    var scan_queue = std.ArrayList(Str).init(tmp_arena);
    try scan_queue.append(try site.strs.intern(""));

    jobs_loop: while (scan_queue.popOrNull()) |dir| {
        var iterator = try SourceDirIterator.init(site, source_root, dir) orelse continue :jobs_loop;
        defer iterator.deinit();
        paths_loop: while (try iterator.next()) |entry| {
            const source_path = entry.path;
            if (entry.is_dir) {
                try scan_queue.append(source_path);
                continue :paths_loop;
            }

            const source_path_bytes = source_path.bytes();
            pattern_loop: for (bootstrap_ignore_patterns) |bootstrap_ignore_pattern| {
                const path = site.strs.get(source_path_bytes) orelse continue :pattern_loop;
                if (path != bootstrap_ignore_pattern) continue :pattern_loop;
                try ignore_patterns.append(path);
                continue :paths_loop;
            }

            const pattern_bytes = try patternForPath(tmp_arena, source_path_bytes);
            const pattern = try site.strs.intern(pattern_bytes);
            var patterns = if (Site.isMarkdown(source_path_bytes))
                &markdown_patterns
            else
                &static_patterns;
            for (patterns.items) |existing_pattern| {
                if (pattern == existing_pattern) break;
            } else {
                try patterns.append(pattern);
            }
            site.rules[0].patterns = static_patterns.items;
            site.rules[1].patterns = markdown_patterns.items;
        }
    }

    site.rules[0].patterns = try site_arena.dupe(Str, site.rules[0].patterns);
    site.rules[1].patterns = try site_arena.dupe(Str, site.rules[1].patterns);
    site.ignore_patterns = try site_arena.dupe(Str, ignore_patterns.items);
}

test bootstrapRules {
    var test_site = try TestSite.init(.{});
    defer test_site.deinit();
    var site = test_site.site;

    try site.source_root.makeDir("markdown_only");
    try site.source_root.makeDir("static_only");
    try site.source_root.makeDir("mixed");

    try site.source_root.writeFile(.{ .sub_path = "markdown_only/one.md", .data = "{}\x02" });
    try site.source_root.writeFile(.{ .sub_path = "markdown_only/two.md", .data = "{}\x02" });
    try site.source_root.writeFile(.{ .sub_path = "static_only/main.css", .data = "" });
    try site.source_root.writeFile(.{ .sub_path = "static_only/logo.png", .data = "" });
    try site.source_root.writeFile(.{ .sub_path = "mixed/three.md", .data = "{}\x02" });
    try site.source_root.writeFile(.{ .sub_path = "mixed/rss.xml", .data = "" });
    try site.source_root.writeFile(.{ .sub_path = "index.md", .data = "{}\x02" });
    try site.source_root.writeFile(.{ .sub_path = ".gitignore", .data = "" });

    var source_root = try site.openSourceRoot(.{ .iterate = true });
    defer source_root.close();

    try bootstrapRules(
        std.testing.allocator,
        site,
        source_root,
    );

    try std.testing.expectEqual(3, site.ignore_patterns.len);
    const ignore_patterns = try std.testing.allocator.dupe(Str, site.ignore_patterns);
    defer std.testing.allocator.free(ignore_patterns);
    std.sort.insertion(Str, ignore_patterns, {}, compareStrings);
    try std.testing.expectEqualStrings(".gitignore", ignore_patterns[0].bytes());
    try std.testing.expectEqualStrings("build", ignore_patterns[1].bytes());
    try std.testing.expectEqualStrings("build.roc", ignore_patterns[2].bytes());

    try std.testing.expectEqual(2, site.rules.len);

    try std.testing.expectEqual(.none, site.rules[0].processing);
    try std.testing.expectEqual(3, site.rules[0].patterns.len);
    const static_patterns = try std.testing.allocator.dupe(Str, site.rules[0].patterns);
    defer std.testing.allocator.free(static_patterns);
    std.sort.insertion(Str, static_patterns, {}, compareStrings);
    try std.testing.expectEqualStrings("mixed/*.xml", static_patterns[0].bytes());
    try std.testing.expectEqualStrings("static_only/*.css", static_patterns[1].bytes());
    try std.testing.expectEqualStrings("static_only/*.png", static_patterns[2].bytes());

    try std.testing.expectEqual(.markdown, site.rules[1].processing);
    try std.testing.expectEqual(3, site.rules[1].patterns.len);
    const markdown_patterns = try std.testing.allocator.dupe(Str, site.rules[1].patterns);
    defer std.testing.allocator.free(markdown_patterns);
    std.sort.insertion(Str, markdown_patterns, {}, compareStrings);
    try std.testing.expectEqualStrings("*.md", markdown_patterns[0].bytes());
    try std.testing.expectEqualStrings("markdown_only/*.md", markdown_patterns[1].bytes());
    try std.testing.expectEqualStrings("mixed/*.md", markdown_patterns[2].bytes());
}

fn compareStrings(_: void, lhs: Str, rhs: Str) bool {
    return std.mem.order(u8, lhs.bytes(), rhs.bytes()).compare(std.math.CompareOperator.lt);
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

fn generateCodeForRules(site: *const Site, source_root: std.fs.Dir) !void {
    const file = try source_root.openFile(site.roc_main.bytes(), .{ .mode = .read_write });
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
        , .{ site.roc_main.bytes(), site.roc_main.bytes(), site.roc_main.bytes() });
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
        \\main =
        \\    { Pages.rules <-
        \\
    );
    for (site.rules) |rule| {
        switch (rule.processing) {
            .markdown => try writer.writeAll("        markdown,\n"),
            .none => {
                try writer.writeAll(
                    \\        Pages.files [
                );
                for (rule.patterns, 0..) |pattern, index| {
                    try writer.print("\"{s}\"", .{pattern.bytes()});
                    if (index < rule.patterns.len - 1) {
                        try writer.writeAll(", ");
                    }
                }
                try writer.writeAll(
                    \\],
                    \\
                );
            },
            .xml => unreachable,
        }
    }
    try writer.writeAll(
        \\        Pages.ignore [
    );
    const user_ignore_patterns = site.user_ignore_patterns();
    for (user_ignore_patterns, 0..) |pattern, index| {
        try writer.print("\"{s}\"", .{pattern.bytes()});
        if (index < user_ignore_patterns.len - 1) {
            try writer.writeAll(", ");
        }
    }
    try writer.writeAll(
        \\],
        \\
    );
    try writer.writeAll(
        \\    }
        \\
        \\
    );
    for (site.rules) |rule| {
        switch (rule.processing) {
            .markdown => {
                try writer.writeAll(
                    \\markdown =
                    \\    Pages.files [
                );
                for (rule.patterns, 0..) |pattern, index| {
                    try writer.print("\"{s}\"", .{pattern.bytes()});
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
            .xml => {},
        }
    }
}

test generateCodeForRules {
    var test_site = try TestSite.init(.{
        .markdown_patterns = &.{ "posts/*.md", "*.md" },
        .static_patterns = &.{"static"},
    });
    defer test_site.deinit();
    var site = test_site.site;

    try site.source_root.writeFile(.{
        .sub_path = "build.roc",
        .data =
        \\app [main] { pf: platform "some hash here" }
        \\
        \\import pf.Pages
        \\
        \\main = Pages.bootstrap
        ,
    });
    var ignore_patterns = [_]Str{
        try site.strs.intern("build.roc"),
        try site.strs.intern("build"),
        try site.strs.intern(".git"),
        try site.strs.intern(".gitignore"),
    };
    site.ignore_patterns = &ignore_patterns;

    try generateCodeForRules(site, site.source_root);

    const generated = try site.source_root.readFileAlloc(std.testing.allocator, "build.roc", 1024 * 1024);
    defer std.testing.allocator.free(generated);
    try std.testing.expectEqualStrings(
        \\app [main] { pf: platform "some hash here" }
        \\
        \\import pf.Pages
        \\import pf.Html
        \\
        \\main =
        \\    { Pages.rules <-
        \\        markdown,
        \\        Pages.files ["static"],
        \\        Pages.ignore [".git", ".gitignore"],
        \\    }
        \\
        \\markdown =
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
    , generated);
}
