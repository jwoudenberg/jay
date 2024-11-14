// Module responsible for generating an initial set of build rules for a
// project, based on the markdown, html, and other source files present in
// the project directory.

const std = @import("std");
const Site = @import("site.zig").Site;
const fail = @import("fail.zig");
const scan = @import("scan.zig");
const WorkQueue = @import("work.zig").WorkQueue;

// When running the bootstrap script we have to guess which files the user
// might want to be ignored. This is our list of such guesses.
const bootstrap_ignore_patterns = [_][]const u8{
    ".git",
    ".gitignore",
    "README*",
};

pub fn bootstrap(
    gpa: std.mem.Allocator,
    site: *Site,
    work: *WorkQueue,
) !void {
    try bootstrapRules(gpa, site, work);
    try generateCodeForRules(site);
}

fn bootstrapRules(
    gpa: std.mem.Allocator,
    site: *Site,
    work: *WorkQueue,
) !void {
    const site_arena = site.allocator();
    var tmp_arena_state = std.heap.ArenaAllocator.init(gpa);
    defer tmp_arena_state.deinit();
    const tmp_arena = tmp_arena_state.allocator();
    var ignore_patterns = std.ArrayList([]const u8).fromOwnedSlice(
        tmp_arena,
        try tmp_arena.dupe([]const u8, site.ignore_patterns),
    );
    defer ignore_patterns.deinit();

    // We're going to scan for files and create rules to contain those files,
    // but we don't know what rules we'll create upfront. Possibilities are
    // a markdown rule, a static file rule, and an ignore rule, but we might
    // not need all three.

    const PreRule = struct {
        rule_index: usize,
        patterns: std.ArrayList([]const u8),
    };
    const processing_type_count = 8 * @sizeOf(Site.Processing);
    var pre_rules: [processing_type_count]?PreRule = std.mem.zeroes([processing_type_count]?PreRule);

    var source_iterator = try scan.SourceFileWalker.init(tmp_arena, site);
    defer source_iterator.deinit();
    iter: while (try source_iterator.next()) |path| {
        for (bootstrap_ignore_patterns) |bootstrap_ignore_pattern| {
            if (std.mem.eql(u8, bootstrap_ignore_pattern, path)) {
                try ignore_patterns.append(try site_arena.dupe(u8, path));
                source_iterator.skip();
                continue :iter;
            }
        }

        const processing: Site.Processing = if (scan.isMarkdown(path)) .markdown else .none;
        const pre_rule_index = @intFromEnum(processing);

        if (pre_rules[pre_rule_index] == null) {
            var rule_index: usize = 0;
            for (pre_rules) |pre_rule| {
                if (pre_rule != null) rule_index += 1;
            }
            pre_rules[pre_rule_index] = PreRule{
                .rule_index = rule_index,
                .patterns = std.ArrayList([]const u8).init(tmp_arena),
            };
        }

        if (pre_rules[pre_rule_index]) |*pre_rule| {
            const page_index = try scan.addPath(
                tmp_arena,
                site,
                pre_rule.rule_index,
                processing,
                try site_arena.dupe(u8, path),
            );
            try work.push(.{ .generate_page = page_index });

            const new_pattern = try patternForPath(tmp_arena, path);
            defer tmp_arena.free(new_pattern);
            for (pre_rule.patterns.items) |existing_pattern| {
                if (std.mem.eql(u8, existing_pattern, new_pattern)) break;
            } else {
                try pre_rule.patterns.append(try site_arena.dupe(u8, new_pattern));
            }
        } else return error.UnexpectedMissingPreRule;
    }

    var rules = try site_arena.alloc(Site.Rule, processing_type_count);
    var rules_len: usize = 0;

    for (pre_rules, 0..) |opt_pre_rule, processing| {
        const pre_rule = opt_pre_rule orelse continue;
        rules_len += 1;
        rules[pre_rule.rule_index] = Site.Rule{
            .patterns = try site_arena.dupe([]const u8, pre_rule.patterns.items),
            .processing = @enumFromInt(processing),
            .replaceTags = &.{},
        };
    }
    site.ignore_patterns = try site_arena.dupe([]const u8, ignore_patterns.items);
    site.rules = rules[0..rules_len];
}

test "bootstrapRules" {
    var tmpdir = std.testing.tmpDir(.{ .iterate = true });
    defer tmpdir.cleanup();

    try tmpdir.dir.writeFile(.{ .sub_path = "build.roc", .data = "" });
    const roc_main = try tmpdir.dir.realpathAlloc(std.testing.allocator, "build.roc");
    defer std.testing.allocator.free(roc_main);
    var site = try Site.init(std.testing.allocator, roc_main, "output");
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

    var work = WorkQueue.init(std.testing.allocator);
    defer work.deinit();
    try bootstrapRules(std.testing.allocator, &site, &work);

    try std.testing.expectEqual(4, site.ignore_patterns.len);
    try std.testing.expectEqualStrings("output", site.ignore_patterns[0]);
    try std.testing.expectEqualStrings("build.roc", site.ignore_patterns[1]);
    try std.testing.expectEqualStrings("build", site.ignore_patterns[2]);
    try std.testing.expectEqualStrings(".gitignore", site.ignore_patterns[3]);

    try std.testing.expectEqual(2, site.rules.len);

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

    try std.testing.expectEqual(7, site.web_paths.count());

    const one_md = site.pages.at(@intFromEnum(site.web_paths.get("/markdown_only/one").?));
    try std.testing.expectEqualStrings(one_md.source_path, "markdown_only/one.md");
    try std.testing.expectEqualStrings(one_md.output_path, "/markdown_only/one.html");
    try std.testing.expectEqual(one_md.rule_index, 0);

    const two_md = site.pages.at(@intFromEnum(site.web_paths.get("/markdown_only/two").?));
    try std.testing.expectEqualStrings(two_md.source_path, "markdown_only/two.md");
    try std.testing.expectEqualStrings(two_md.output_path, "/markdown_only/two.html");
    try std.testing.expectEqual(two_md.rule_index, 0);

    const main_css = site.pages.at(@intFromEnum(site.web_paths.get("/static_only/main.css").?));
    try std.testing.expectEqualStrings(main_css.source_path, "static_only/main.css");
    try std.testing.expectEqualStrings(main_css.output_path, "/static_only/main.css");
    try std.testing.expectEqual(main_css.rule_index, 1);

    const logo_png = site.pages.at(@intFromEnum(site.web_paths.get("/static_only/logo.png").?));
    try std.testing.expectEqualStrings(logo_png.source_path, "static_only/logo.png");
    try std.testing.expectEqualStrings(logo_png.output_path, "/static_only/logo.png");
    try std.testing.expectEqual(logo_png.rule_index, 1);

    const three_md = site.pages.at(@intFromEnum(site.web_paths.get("/mixed/three").?));
    try std.testing.expectEqualStrings(three_md.source_path, "mixed/three.md");
    try std.testing.expectEqualStrings(three_md.output_path, "/mixed/three.html");
    try std.testing.expectEqual(three_md.rule_index, 0);

    const rss_xml = site.pages.at(@intFromEnum(site.web_paths.get("/mixed/rss.xml").?));
    try std.testing.expectEqualStrings(rss_xml.source_path, "mixed/rss.xml");
    try std.testing.expectEqualStrings(rss_xml.output_path, "/mixed/rss.xml");
    try std.testing.expectEqual(rss_xml.rule_index, 1);

    const index_md = site.pages.at(@intFromEnum(site.web_paths.get("/").?));
    try std.testing.expectEqualStrings(index_md.source_path, "index.md");
    try std.testing.expectEqualStrings(index_md.output_path, "/index.html");
    try std.testing.expectEqual(index_md.rule_index, 0);
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
            .xml => unreachable,
        }
    }
    try writer.writeAll(
        \\    Pages.ignore [
    );
    for (site.ignore_patterns, 0..) |pattern, index| {
        try writer.print("\"{s}\"", .{pattern});
        if (index < site.ignore_patterns.len - 1) {
            try writer.writeAll(", ");
        }
    }
    try writer.writeAll(
        \\],
        \\
    );
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
            .xml => {},
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
    var site = try Site.init(std.testing.allocator, roc_main, "output");
    defer site.deinit();
    var rules = [_]Site.Rule{
        Site.Rule{
            .processing = .markdown,
            .patterns = ([_][]const u8{ "posts/*.md", "*.md" })[0..],
            .replaceTags = &[_][]const u8{},
        },
        Site.Rule{
            .processing = .none,
            .patterns = ([_][]const u8{"static"})[0..],
            .replaceTags = &[_][]const u8{},
        },
    };
    site.rules = rules[0..];
    site.ignore_patterns = ([_][]const u8{ ".git", ".gitignore" })[0..];

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
