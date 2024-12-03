// Module responsible for generating an initial set of build rules for a
// project, based on the markdown, html, and other source files present in
// the project directory.

const builtin = @import("builtin");
const std = @import("std");
const Site = @import("site.zig").Site;
const fail = @import("fail.zig");
const scan = @import("scan.zig");
const Watcher = @import("watch.zig").Watcher(Path, Path.bytes);
const WorkQueue = @import("work.zig").WorkQueue;
const Path = @import("path.zig").Path;
const generate = @import("generate.zig").generate;
const platform = @import("generate.zig").platform;

// When running the bootstrap script we have to guess which files the user
// might want to be ignored. This is our list of such guesses.
const bootstrap_ignore_patterns = [_][]const u8{
    ".git",
    ".gitignore",
    "README*",
};

pub fn bootstrap(
    gpa: std.mem.Allocator,
    paths: *Path.Registry,
    site: *Site,
    watcher: *Watcher,
    work: *WorkQueue,
) !void {
    var source_root = try site.openSourceRoot(.{ .iterate = true });
    defer source_root.close();

    try bootstrapRules(gpa, paths, site, watcher, work, source_root);
    try generateCodeForRules(site, source_root);
}

// To bootstrap we scan the project and build up the site rules while also
// adding pages. An attempt to reuse logic from other places as much as
// possible makes it a bit hacky.
fn bootstrapRules(
    gpa: std.mem.Allocator,
    paths: *Path.Registry,
    site: *Site,
    watcher: *Watcher,
    work: *WorkQueue,
    source_root: std.fs.Dir,
) !void {
    const site_arena = site.allocator();

    var tmp_arena_state = std.heap.ArenaAllocator.init(gpa);
    defer tmp_arena_state.deinit();
    const tmp_arena = tmp_arena_state.allocator();
    var ignore_patterns = std.ArrayList([]const u8).init(tmp_arena);
    try ignore_patterns.appendSlice(site.ignore_patterns);
    var markdown_patterns = std.ArrayList([]const u8).init(tmp_arena);
    var static_patterns = std.ArrayList([]const u8).init(tmp_arena);

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
    try bootstrap_work.push(.{ .scan_dir = try paths.intern("") });

    // TODO: reinit arena after each iteration.
    jobs_loop: while (bootstrap_work.pop()) |job| {
        switch (job) {
            .scan_file => {
                const source_path = job.scan_file;
                const source_path_bytes = source_path.bytes();

                for (bootstrap_ignore_patterns) |bootstrap_ignore_pattern| {
                    if (std.mem.eql(u8, bootstrap_ignore_pattern, source_path_bytes)) {
                        try ignore_patterns.append(try site_arena.dupe(u8, source_path_bytes));
                        continue :jobs_loop;
                    }
                }

                const new_pattern = try patternForPath(tmp_arena, source_path_bytes);
                var patterns = if (Site.isMarkdown(source_path_bytes))
                    &markdown_patterns
                else
                    &static_patterns;
                for (patterns.items) |existing_pattern| {
                    if (std.mem.eql(u8, existing_pattern, new_pattern)) break;
                } else {
                    try patterns.append(try site_arena.dupe(u8, new_pattern));
                }
                site.rules[0].patterns = static_patterns.items;
                site.rules[1].patterns = markdown_patterns.items;

                try scan.scanFile(tmp_arena, &bootstrap_work, site, source_root, source_path);
            },
            .scan_dir => {
                try scan.scanDir(
                    &bootstrap_work,
                    paths,
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

    site.rules[0].patterns = try site_arena.dupe([]const u8, site.rules[0].patterns);
    site.rules[1].patterns = try site_arena.dupe([]const u8, site.rules[1].patterns);
    site.ignore_patterns = try site_arena.dupe([]const u8, ignore_patterns.items);
}

test "bootstrapRules" {
    var tmpdir = std.testing.tmpDir(.{ .iterate = true });
    defer tmpdir.cleanup();

    try tmpdir.dir.writeFile(.{ .sub_path = "build.roc", .data = "" });
    const roc_main = try tmpdir.dir.realpathAlloc(std.testing.allocator, "build.roc");
    defer std.testing.allocator.free(roc_main);
    var paths = Path.Registry.init(std.testing.allocator);
    defer paths.deinit();
    var site = try Site.init(std.testing.allocator, roc_main, "output", &paths);
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
    var watcher = try Watcher.init(std.testing.allocator, tmpdir.dir);
    defer watcher.deinit();

    try bootstrapRules(std.testing.allocator, &paths, &site, &watcher, &work, tmpdir.dir);

    try std.testing.expectEqual(4, site.ignore_patterns.len);
    try std.testing.expectEqualStrings("output", site.ignore_patterns[0]);
    try std.testing.expectEqualStrings("build.roc", site.ignore_patterns[1]);
    try std.testing.expectEqualStrings("build", site.ignore_patterns[2]);
    try std.testing.expectEqualStrings(".gitignore", site.ignore_patterns[3]);

    try std.testing.expectEqual(2, site.rules.len);

    try std.testing.expectEqual(.none, site.rules[0].processing);
    try std.testing.expectEqual(3, site.rules[0].patterns.len);
    const static_patterns = try std.testing.allocator.dupe([]const u8, site.rules[0].patterns);
    defer std.testing.allocator.free(static_patterns);
    std.sort.insertion([]const u8, static_patterns, {}, compareStrings);
    try std.testing.expectEqualStrings("mixed/*.xml", static_patterns[0]);
    try std.testing.expectEqualStrings("static_only/*.css", static_patterns[1]);
    try std.testing.expectEqualStrings("static_only/*.png", static_patterns[2]);

    try std.testing.expectEqual(.markdown, site.rules[1].processing);
    try std.testing.expectEqual(3, site.rules[1].patterns.len);
    const markdown_patterns = try std.testing.allocator.dupe([]const u8, site.rules[1].patterns);
    defer std.testing.allocator.free(markdown_patterns);
    std.sort.insertion([]const u8, markdown_patterns, {}, compareStrings);
    try std.testing.expectEqualStrings("*.md", markdown_patterns[0]);
    try std.testing.expectEqualStrings("markdown_only/*.md", markdown_patterns[1]);
    try std.testing.expectEqualStrings("mixed/*.md", markdown_patterns[2]);

    const one_md = site.getPage(try paths.intern("markdown_only/one")).?;
    try std.testing.expectEqualStrings("markdown_only/one.md", one_md.source_path.bytes());
    try std.testing.expectEqualStrings("markdown_only/one.html", one_md.output_path.bytes());
    try std.testing.expectEqual(one_md.rule_index, 1);

    const two_md = site.getPage(try paths.intern("markdown_only/two")).?;
    try std.testing.expectEqualStrings("markdown_only/two.md", two_md.source_path.bytes());
    try std.testing.expectEqualStrings("markdown_only/two.html", two_md.output_path.bytes());
    try std.testing.expectEqual(two_md.rule_index, 1);

    const main_css = site.getPage(try paths.intern("static_only/main.css")).?;
    try std.testing.expectEqualStrings("static_only/main.css", main_css.source_path.bytes());
    try std.testing.expectEqualStrings("static_only/main.css", main_css.output_path.bytes());
    try std.testing.expectEqual(main_css.rule_index, 0);

    const logo_png = site.getPage(try paths.intern("static_only/logo.png")).?;
    try std.testing.expectEqualStrings("static_only/logo.png", logo_png.source_path.bytes());
    try std.testing.expectEqualStrings("static_only/logo.png", logo_png.output_path.bytes());
    try std.testing.expectEqual(logo_png.rule_index, 0);

    const three_md = site.getPage(try paths.intern("mixed/three")).?;
    try std.testing.expectEqualStrings("mixed/three.md", three_md.source_path.bytes());
    try std.testing.expectEqualStrings("mixed/three.html", three_md.output_path.bytes());
    try std.testing.expectEqual(three_md.rule_index, 1);

    const rss_xml = site.getPage(try paths.intern("mixed/rss.xml")).?;
    try std.testing.expectEqualStrings("mixed/rss.xml", rss_xml.source_path.bytes());
    try std.testing.expectEqualStrings("mixed/rss.xml", rss_xml.output_path.bytes());
    try std.testing.expectEqual(rss_xml.rule_index, 0);

    const index_md = site.getPage(try paths.intern("")).?;
    try std.testing.expectEqualStrings("index.md", index_md.source_path.bytes());
    try std.testing.expectEqualStrings("index.html", index_md.output_path.bytes());
    try std.testing.expectEqual(index_md.rule_index, 1);
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
        \\        Pages.ignore [
    );
    const user_ignore_patterns = site.user_ignore_patterns();
    for (user_ignore_patterns, 0..) |pattern, index| {
        try writer.print("\"{s}\"", .{pattern});
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
    var paths = Path.Registry.init(std.testing.allocator);
    defer paths.deinit();
    var site = try Site.init(std.testing.allocator, roc_main, "output", &paths);
    defer site.deinit();
    var rules = [_]Site.Rule{
        Site.Rule{
            .processing = .markdown,
            .patterns = ([_][]const u8{ "posts/*.md", "*.md" })[0..],
            .replace_tags = &.{},
        },
        Site.Rule{
            .processing = .none,
            .patterns = ([_][]const u8{"static"})[0..],
            .replace_tags = &.{},
        },
    };
    site.rules = rules[0..];
    site.ignore_patterns = &.{
        "build.roc",
        "build",
        "output",
        ".git",
        ".gitignore",
    };

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
