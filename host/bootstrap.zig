// Module responsible for generating an initial set of build rules for a
// project, based on the markdown, html, and other source files present in
// the project directory.

const std = @import("std");
const Site = @import("site.zig").Site;
const fail = @import("fail.zig");
const scan = @import("scan.zig");
const Watcher = @import("watch.zig").Watcher(Str, Str.bytes);
const WorkQueue = @import("work.zig").WorkQueue;
const Str = @import("str.zig").Str;

pub fn bootstrap(
    gpa: std.mem.Allocator,
    strs: *Str.Registry,
    site: *Site,
    watcher: *Watcher,
    work: *WorkQueue,
) !void {
    var source_root = try site.openSourceRoot(.{ .iterate = true });
    defer source_root.close();

    try bootstrapRules(gpa, strs, site, watcher, work, source_root);
    try generateCodeForRules(site, source_root);
}

// To bootstrap we scan the project and build up the site rules while also
// adding pages. An attempt to reuse logic from other places as much as
// possible makes it a bit hacky.
fn bootstrapRules(
    gpa: std.mem.Allocator,
    strs: *Str.Registry,
    site: *Site,
    watcher: *Watcher,
    work: *WorkQueue,
    source_root: std.fs.Dir,
) !void {
    const site_arena = site.allocator();

    var tmp_arena_state = std.heap.ArenaAllocator.init(gpa);
    defer tmp_arena_state.deinit();
    const tmp_arena = tmp_arena_state.allocator();
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

    var bootstrap_work = WorkQueue.init(tmp_arena);

    // Queue a job to scan the root source directory. This will result in
    // the entire project getting scanned and output generated.
    try bootstrap_work.push(.{ .scan_dir = try strs.intern("") });

    // When running the bootstrap script we have to guess which files the user
    // might want to be ignored. This is our list of such guesses.
    const bootstrap_ignore_patterns = [_]Str{
        try strs.intern(".git"),
        try strs.intern(".gitignore"),
        try strs.intern("README*"),
    };

    // TODO: reinit arena after each iteration.
    jobs_loop: while (bootstrap_work.pop()) |job| {
        switch (job) {
            .scan_file => {
                const source_path = job.scan_file;
                const source_path_bytes = source_path.bytes();

                pattern_loop: for (bootstrap_ignore_patterns) |bootstrap_ignore_pattern| {
                    const path = strs.get(source_path_bytes) orelse continue :pattern_loop;
                    if (path != bootstrap_ignore_pattern) continue :pattern_loop;
                    try ignore_patterns.append(path);
                    continue :jobs_loop;
                }

                const pattern_bytes = try patternForPath(tmp_arena, source_path_bytes);
                const pattern = try strs.intern(pattern_bytes);
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

                try scan.scanFile(&bootstrap_work, site, source_path);
            },
            .scan_dir => {
                try scan.scanDir(
                    &bootstrap_work,
                    strs,
                    site,
                    watcher,
                    source_root,
                    job.scan_dir,
                );
            },
            .generate_file => {
                // Push generate jobs into the main queue, to run later.
                try work.push(job);
            },
        }
    }

    site.rules[0].patterns = try site_arena.dupe(Str, site.rules[0].patterns);
    site.rules[1].patterns = try site_arena.dupe(Str, site.rules[1].patterns);
    site.ignore_patterns = try site_arena.dupe(Str, ignore_patterns.items);
}

test "bootstrapRules" {
    var tmpdir = std.testing.tmpDir(.{ .iterate = true });
    defer tmpdir.cleanup();

    var strs = Str.Registry.init(std.testing.allocator);
    defer strs.deinit();
    var site = try Site.init(std.testing.allocator, tmpdir.dir, "build.roc", "output", &strs);
    defer site.deinit();

    try tmpdir.dir.makeDir("markdown_only");
    try tmpdir.dir.makeDir("static_only");
    try tmpdir.dir.makeDir("mixed");

    try tmpdir.dir.writeFile(.{ .sub_path = "markdown_only/one.md", .data = "{}\x02" });
    try tmpdir.dir.writeFile(.{ .sub_path = "markdown_only/two.md", .data = "{}\x02" });
    try tmpdir.dir.writeFile(.{ .sub_path = "static_only/main.css", .data = "" });
    try tmpdir.dir.writeFile(.{ .sub_path = "static_only/logo.png", .data = "" });
    try tmpdir.dir.writeFile(.{ .sub_path = "mixed/three.md", .data = "{}\x02" });
    try tmpdir.dir.writeFile(.{ .sub_path = "mixed/rss.xml", .data = "" });
    try tmpdir.dir.writeFile(.{ .sub_path = "index.md", .data = "{}\x02" });
    try tmpdir.dir.writeFile(.{ .sub_path = ".gitignore", .data = "" });

    var work = WorkQueue.init(std.testing.allocator);
    defer work.deinit();
    var watcher = try Watcher.init(std.testing.allocator, tmpdir.dir);
    defer watcher.deinit();

    try bootstrapRules(std.testing.allocator, &strs, &site, &watcher, &work, tmpdir.dir);

    try std.testing.expectEqual(4, site.ignore_patterns.len);
    try std.testing.expectEqualStrings("output", site.ignore_patterns[0].bytes());
    try std.testing.expectEqualStrings("build.roc", site.ignore_patterns[1].bytes());
    try std.testing.expectEqualStrings("build", site.ignore_patterns[2].bytes());
    try std.testing.expectEqualStrings(".gitignore", site.ignore_patterns[3].bytes());

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

    const one_md = site.getPage(try strs.intern("markdown_only/one")).?;
    try std.testing.expectEqualStrings("markdown_only/one.md", one_md.source_path.bytes());
    try std.testing.expectEqualStrings("markdown_only/one.html", one_md.output_path.bytes());
    try std.testing.expectEqual(one_md.rule_index, 1);

    const two_md = site.getPage(try strs.intern("markdown_only/two")).?;
    try std.testing.expectEqualStrings("markdown_only/two.md", two_md.source_path.bytes());
    try std.testing.expectEqualStrings("markdown_only/two.html", two_md.output_path.bytes());
    try std.testing.expectEqual(two_md.rule_index, 1);

    const main_css = site.getPage(try strs.intern("static_only/main.css")).?;
    try std.testing.expectEqualStrings("static_only/main.css", main_css.source_path.bytes());
    try std.testing.expectEqualStrings("static_only/main.css", main_css.output_path.bytes());
    try std.testing.expectEqual(main_css.rule_index, 0);

    const logo_png = site.getPage(try strs.intern("static_only/logo.png")).?;
    try std.testing.expectEqualStrings("static_only/logo.png", logo_png.source_path.bytes());
    try std.testing.expectEqualStrings("static_only/logo.png", logo_png.output_path.bytes());
    try std.testing.expectEqual(logo_png.rule_index, 0);

    const three_md = site.getPage(try strs.intern("mixed/three")).?;
    try std.testing.expectEqualStrings("mixed/three.md", three_md.source_path.bytes());
    try std.testing.expectEqualStrings("mixed/three.html", three_md.output_path.bytes());
    try std.testing.expectEqual(three_md.rule_index, 1);

    const rss_xml = site.getPage(try strs.intern("mixed/rss.xml")).?;
    try std.testing.expectEqualStrings("mixed/rss.xml", rss_xml.source_path.bytes());
    try std.testing.expectEqualStrings("mixed/rss.xml", rss_xml.output_path.bytes());
    try std.testing.expectEqual(rss_xml.rule_index, 0);

    const index_md = site.getPage(try strs.intern("")).?;
    try std.testing.expectEqualStrings("index.md", index_md.source_path.bytes());
    try std.testing.expectEqualStrings("index.html", index_md.output_path.bytes());
    try std.testing.expectEqual(index_md.rule_index, 1);
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
    const file = try source_root.openFile(site.roc_main, .{ .mode = .read_write });
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
    var strs = Str.Registry.init(std.testing.allocator);
    defer strs.deinit();
    var site = try Site.init(std.testing.allocator, tmpdir.dir, "build.roc", "output", &strs);
    defer site.deinit();
    var rules = [_]Site.Rule{
        Site.Rule{
            .processing = .markdown,
            .patterns = try site.strsFromSlices(&.{ "posts/*.md", "*.md" }),
            .replace_tags = &.{},
        },
        Site.Rule{
            .processing = .none,
            .patterns = try site.strsFromSlices(&.{"static"}),
            .replace_tags = &.{},
        },
    };
    site.rules = rules[0..];
    var ignore_patterns = [_]Str{
        try strs.intern("build.roc"),
        try strs.intern("build"),
        try strs.intern("output"),
        try strs.intern(".git"),
        try strs.intern(".gitignore"),
    };
    site.ignore_patterns = &ignore_patterns;

    try generateCodeForRules(&site, tmpdir.dir);

    const generated = try tmpdir.dir.readFileAlloc(std.testing.allocator, "build.roc", 1024 * 1024);
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
