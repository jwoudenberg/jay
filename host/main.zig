const std = @import("std");
const builtin = @import("builtin");
const RocStr = @import("roc/str.zig").RocStr;
const RocList = @import("roc/list.zig").RocList;
const Str = @import("str.zig").Str;
const fail = @import("fail.zig");
const Site = @import("site.zig").Site;
const Watcher = @import("watch.zig").Watcher(Str, Str.bytes);
const glob = @import("glob.zig");
const serve = @import("serve.zig").serve;
const platform = @import("platform.zig").platform;
const bootstrap = @import("bootstrap.zig").bootstrap;
const scanRecursively = @import("scan.zig").scanRecursively;

pub fn main() void {
    if (run()) {} else |err| {
        fail.crudely(err, @errorReturnTrace());
    }
}

var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
const gpa = gpa_state.allocator();

fn run() !void {
    var strs = try Str.Registry.init(gpa);
    defer strs.deinit();
    var site = try createSite(strs);
    defer site.deinit();
    const should_bootstrap = try platform.getRules(gpa, &site);

    var watcher = try Watcher.init(gpa, try site.openSourceRoot(.{}));
    defer watcher.deinit();
    var runLoop = try RunLoop.init(&site, &watcher, should_bootstrap);

    // TODO: handle thread failures.
    const thread = try std.Thread.spawn(.{}, serve, .{&site});
    thread.detach();

    var stdout = std.io.getStdOut().writer();
    while (true) try runLoop.loopOnce(&stdout);
}

// The core watch/generate loop of the app extracted in a format that I can
// relatively easily write tests for.
const RunLoop = struct {
    site: *Site,
    watcher: *Watcher,

    fn init(site: *Site, watcher: *Watcher, should_bootstrap: bool) !RunLoop {
        if (site.rules.len == 0 and should_bootstrap) {
            try bootstrap(gpa, site);
        }

        try scanRecursively(gpa, site, watcher, try site.strs.intern(""));
        try site.generatePages();

        return .{
            .site = site,
            .watcher = watcher,
        };
    }

    fn loopOnce(self: *RunLoop, writer: anytype) !void {
        while (try self.watcher.next_wait(50)) |change| {
            try handle_change(self.site, self.watcher, change);
        }
        // No new events in the last watch period, so filesystem changes
        // have settled.
        try self.site.generatePages();
        try self.site.errors.print(writer);
    }
};

fn createSite(strs: Str.Registry) !Site {
    var args = std.process.args();
    const argv0 = args.next() orelse return error.EmptyArgv;
    const source_root_path = std.fs.path.dirname(argv0) orelse "./";
    const roc_main = std.fs.path.basename(argv0);
    const source_root = std.fs.cwd().openDir(source_root_path, .{}) catch |err| {
        try fail.prettily(
            "Cannot access directory containing {s}: '{}'\n",
            .{ source_root_path, err },
        );
    };
    return Site.init(gpa, source_root, roc_main, "output", strs);
}

fn handle_change(
    site: *Site,
    watcher: *Watcher,
    change: Watcher.Change,
) !void {
    switch (change) {
        .changes_missed => {
            try scanRecursively(
                gpa,
                site,
                watcher,
                try site.strs.intern(""),
            );
        },
        .dir_changed => |entry| {
            var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
            const path_bytes = if (entry.dir.bytes().len == 0)
                entry.file_name
            else
                try std.fmt.bufPrint(
                    &buf,
                    "{s}/{s}",
                    .{ entry.dir.bytes(), entry.file_name },
                );
            if (!Site.matchAny(site.ignore_patterns, path_bytes)) {
                const path = try site.strs.intern(path_bytes);
                try scanRecursively(gpa, site, watcher, path);
            }

            // A directory change even might mean something got deleted, so
            // touch all the directory's pages to check they still exist.
            var pages = site.iterator();
            while (pages.next()) |page| {
                if (std.mem.startsWith(u8, page.source_path.bytes(), path_bytes)) {
                    try site.touchPage(page.source_path);
                }
            }
        },
        .file_changed => |entry| {
            var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
            const path_bytes = if (entry.dir.bytes().len == 0)
                entry.file_name
            else
                try std.fmt.bufPrint(
                    &buf,
                    "{s}/{s}",
                    .{ entry.dir.bytes(), entry.file_name },
                );
            if (!Site.matchAny(site.ignore_patterns, path_bytes)) {
                const path = try site.strs.intern(path_bytes);
                try site.touchPage(path);
            }
        },
    }
}

test "add a source file => jay generates an output file for it" {
    var test_run_loop = try TestRunLoop.init(.{ .markdown_patterns = &.{"*.md"} });
    defer test_run_loop.deinit();
    var site = test_run_loop.test_site.site;

    try site.source_root.writeFile(.{ .sub_path = "file.md", .data = "{}<html/>" });
    try test_run_loop.loopOnce();
    try std.testing.expectEqualStrings("", test_run_loop.output());
    try expectFile(site.output_root, "file.html", "<html/>\n");
}

test "delete a source file => jay deletes its output file" {
    var test_run_loop = try TestRunLoop.init(.{ .markdown_patterns = &.{"*.md"} });
    defer test_run_loop.deinit();
    var site = test_run_loop.test_site.site;

    try site.source_root.writeFile(.{ .sub_path = "file.md", .data = "{}<html/>" });
    try test_run_loop.loopOnce();
    try expectFile(site.output_root, "file.html", "<html/>\n");

    try site.source_root.deleteFile("file.md");
    try test_run_loop.loopOnce();
    try expectNoFile(site.output_root, "file.html");
}

test "delete a source file before a page is generated => jay does not create an output file" {
    var test_run_loop = try TestRunLoop.init(.{
        .markdown_patterns = &.{"*.md"},
        .static_patterns = &.{"static*"},
    });
    defer test_run_loop.deinit();
    var site = test_run_loop.test_site.site;
    var run_loop = test_run_loop.run_loop;

    // Test for three file types that we know generate has separate logic for.
    try site.source_root.writeFile(.{ .sub_path = "file.md", .data = "{}<html/>" });
    try site.source_root.writeFile(.{ .sub_path = "static.css", .data = "" });
    try site.source_root.writeFile(.{ .sub_path = "static.html", .data = "" });
    while (try run_loop.watcher.next_wait(50)) |change| {
        try handle_change(site, run_loop.watcher, change);
    }
    try expectNoFile(site.output_root, "file");
    try expectNoFile(site.output_root, "static.css");
    try expectNoFile(site.output_root, "static");

    try site.source_root.deleteFile("file.md");
    try site.source_root.deleteFile("static.css");
    try site.source_root.deleteFile("static.html");
    try test_run_loop.loopOnce();
    try expectNoFile(site.output_root, "file");
    try expectNoFile(site.output_root, "static.css");
    try expectNoFile(site.output_root, "static");
}

test "create a short-lived file that does not match a pattern => jay will not show an error" {
    var test_run_loop = try TestRunLoop.init(.{});
    defer test_run_loop.deinit();
    var site = test_run_loop.test_site.site;

    try site.source_root.writeFile(.{ .sub_path = "file.md", .data = "{}<html/>" });
    try site.source_root.deleteFile("file.md");
    try test_run_loop.loopOnce();
    try expectNoFile(site.output_root, "file.html");
    try std.testing.expectEqualStrings("", test_run_loop.output());
}

test "move a directory out of project dir => jay recursively deletes related output files" {
    var test_run_loop = try TestRunLoop.init(.{ .markdown_patterns = &.{
        "*.md",
        "cellar/subway/*.md",
    } });
    defer test_run_loop.deinit();
    var extern_dir = std.testing.tmpDir(.{});
    defer extern_dir.cleanup();
    var site = test_run_loop.test_site.site;

    try site.source_root.makePath("cellar/subway");
    try site.source_root.writeFile(.{ .sub_path = "file1.md", .data = "{}<html/>" });
    try site.source_root.writeFile(.{ .sub_path = "cellar/subway/file2.md", .data = "{}<html/>" });
    try test_run_loop.loopOnce();
    try expectFile(site.output_root, "file1.html", "<html/>\n");
    try expectFile(site.output_root, "cellar/subway/file2.html", "<html/>\n");

    try std.fs.rename(site.source_root, "cellar", extern_dir.dir, "cellar");
    try test_run_loop.loopOnce();
    try expectFile(site.output_root, "file1.html", "<html/>\n");
    try expectNoFile(site.output_root, "cellar/subway/file2.html");
    try std.testing.expectEqualStrings("", test_run_loop.output());

    // Changing a file after it's been moved out of the project has no effect
    try extern_dir.dir.writeFile(.{ .sub_path = "cellar/subway/file2.md", .data = "{}<span/>" });
    try expectNoFile(site.output_root, "cellar/subway/file2.html");
    try std.testing.expectEqualStrings("", test_run_loop.output());
}

test "move a directory with a file into the project dir => jay generates an output file" {
    var test_run_loop = try TestRunLoop.init(.{ .markdown_patterns = &.{
        "cellar/subway/*.md",
    } });
    defer test_run_loop.deinit();
    var extern_dir = std.testing.tmpDir(.{});
    defer extern_dir.cleanup();
    const site = test_run_loop.test_site.site;

    try extern_dir.dir.makePath("cellar/subway");
    try extern_dir.dir.writeFile(.{ .sub_path = "cellar/subway/file.md", .data = "{}<html/>" });

    try std.fs.rename(extern_dir.dir, "cellar", site.source_root, "cellar");
    try test_run_loop.loopOnce();
    try expectFile(site.output_root, "cellar/subway/file.html", "<html/>\n");
    try std.testing.expectEqualStrings("", test_run_loop.output());
}

test "create a directory then later a file in it => jay generates an output file" {
    var test_run_loop = try TestRunLoop.init(.{ .markdown_patterns = &.{
        "cellar/*.md",
    } });
    defer test_run_loop.deinit();
    const site = test_run_loop.test_site.site;

    try site.source_root.makePath("cellar");
    try test_run_loop.loopOnce();

    try site.source_root.writeFile(.{ .sub_path = "cellar/file.md", .data = "{}<html/>" });
    try test_run_loop.loopOnce();
    try expectFile(site.output_root, "cellar/file.html", "<html/>\n");
    try std.testing.expectEqualStrings("", test_run_loop.output());
}

test "add a file matching an ignore pattern => jay does not generate an output file nor show an error" {
    var test_run_loop = try TestRunLoop.init(.{ .ignore_patterns = &.{"*.md"} });
    defer test_run_loop.deinit();
    const site = test_run_loop.test_site.site;

    try site.source_root.writeFile(.{ .sub_path = "file.md", .data = "{}<html/>" });
    try test_run_loop.loopOnce();
    try expectNoFile(site.output_root, "file.html");
    try std.testing.expectEqualStrings("", test_run_loop.output());
}

test "add a file that does not match a patter => jay will show an error" {
    var test_run_loop = try TestRunLoop.init(.{ .markdown_patterns = &.{} });
    defer test_run_loop.deinit();
    const site = test_run_loop.test_site.site;

    try site.source_root.writeFile(.{ .sub_path = "file.md", .data = "{}<html/>" });
    try test_run_loop.loopOnce();
    try expectNoFile(site.output_root, "file.html");
    try std.testing.expectEqualStrings(
        \\I can't find a pattern matching the following source path:
        \\
        \\    file.md
        \\
        \\Make sure each path in your project directory is matched by
        \\a rule, or an ignore pattern.
        \\
        \\Tip: Add an extra rule like this:
        \\
        \\    Pages.files ["file.md"]
        \\
        \\
    , test_run_loop.output());

    // Remove the file => jay marks the error fixed
    try site.source_root.deleteFile("file.md");
    try test_run_loop.loopOnce();
    try std.testing.expectEqualStrings("", test_run_loop.output());
}

test "add multiple files with a problem => jay will show multiple error" {
    var test_run_loop = try TestRunLoop.init(.{ .markdown_patterns = &.{} });
    defer test_run_loop.deinit();
    const site = test_run_loop.test_site.site;

    try site.source_root.writeFile(.{ .sub_path = "file1.md", .data = "{}<html/>" });
    try site.source_root.writeFile(.{ .sub_path = "file2.md", .data = "{}<html/>" });
    try test_run_loop.loopOnce();
    try std.testing.expectEqualStrings(
        \\I can't find a pattern matching the following source path:
        \\
        \\    file1.md
        \\
        \\Make sure each path in your project directory is matched by
        \\a rule, or an ignore pattern.
        \\
        \\Tip: Add an extra rule like this:
        \\
        \\    Pages.files ["file1.md"]
        \\
        \\
        \\----------------------------------------
        \\
        \\I can't find a pattern matching the following source path:
        \\
        \\    file2.md
        \\
        \\Make sure each path in your project directory is matched by
        \\a rule, or an ignore pattern.
        \\
        \\Tip: Add an extra rule like this:
        \\
        \\    Pages.files ["file2.md"]
        \\
        \\
    , test_run_loop.output());

    // Fix one problem => jay continues to show the remaining problem
    try site.source_root.deleteFile("file1.md");
    try test_run_loop.loopOnce();
    try std.testing.expectEqualStrings(
        \\I can't find a pattern matching the following source path:
        \\
        \\    file2.md
        \\
        \\Make sure each path in your project directory is matched by
        \\a rule, or an ignore pattern.
        \\
        \\Tip: Add an extra rule like this:
        \\
        \\    Pages.files ["file2.md"]
        \\
        \\
    , test_run_loop.output());
}

test "add a file that matches two patterns of the same rule => jay does not show an error" {
    var test_run_loop = try TestRunLoop.init(.{ .markdown_patterns = &.{ "*.md", "file*" } });
    defer test_run_loop.deinit();
    const site = test_run_loop.test_site.site;

    try site.source_root.writeFile(.{ .sub_path = "file.md", .data = "{}<html/>" });
    try test_run_loop.loopOnce();
    try expectFile(site.output_root, "file.html", "<html/>\n");
    try std.testing.expectEqualStrings("", test_run_loop.output());
}

test "add a file matching patterns in two rules => jay shows an error" {
    var test_run_loop = try TestRunLoop.init(.{
        .markdown_patterns = &.{"*.md"},
        .static_patterns = &.{"file*"},
    });
    defer test_run_loop.deinit();
    const site = test_run_loop.test_site.site;

    try site.source_root.writeFile(.{ .sub_path = "file.md", .data = "{}<html/>" });
    try test_run_loop.loopOnce();
    try expectNoFile(site.output_root, "file.html");
    try std.testing.expectEqualStrings(
        \\The following file is matched by multiple rules:
        \\
        \\    file.md
        \\
        \\These are the indices of the rules that match:
        \\
        \\    { 0, 1 }
        \\
        \\
    , test_run_loop.output());

    // Remove the file => jay marks the error fixed
    try site.source_root.deleteFile("file.md");
    try test_run_loop.loopOnce();
    try std.testing.expectEqualStrings("", test_run_loop.output());
}

test "add two files that output the same web path => jay shows an error" {
    var test_run_loop = try TestRunLoop.init(.{
        .markdown_patterns = &.{"*.md"},
        .static_patterns = &.{"*.html"},
    });
    defer test_run_loop.deinit();
    const site = test_run_loop.test_site.site;

    try site.source_root.writeFile(.{ .sub_path = "file.md", .data = "{}<html/>" });
    try site.source_root.writeFile(.{ .sub_path = "file.html", .data = "<span/>" });
    try test_run_loop.loopOnce();
    try expectFile(site.output_root, "file.html", "<html/>\n");
    try std.testing.expectEqualStrings(
        \\I found multiple source files for a single page URL.
        \\
        \\These are the source files in question:
        \\
        \\  file.html
        \\  file.md
        \\
        \\The URL path I would use for both of these is:
        \\
        \\  file
        \\
        \\Tip: Rename one of the files so both get a unique URL.
        \\
    , test_run_loop.output());

    // TODO: make this problem recoverable.
    // // Remove one of the files => jay marks the error fixed
    // try site.source_root.deleteFile("file.md");
    // try test_run_loop.loopOnce();
    // try expectFile(site.output_root, "file.html", "<span/>\n");
    // try std.testing.expectEqualStrings("", test_run_loop.output());
}

test "change a file => jay updates the file and its dependents" {
    var test_run_loop = try TestRunLoop.init(.{ .markdown_patterns = &.{"*.md"} });
    defer test_run_loop.deinit();
    const site = test_run_loop.test_site.site;

    try site.source_root.writeFile(.{ .sub_path = "dep.md", .data = "{ hi: 4 }<html/>" });
    try site.source_root.writeFile(.{ .sub_path = "file.md", .data = "{}<dep pattern=\"dep*\"/>" });
    try test_run_loop.loopOnce();
    try expectFile(site.output_root, "dep.html", "<html/>\n");
    try expectFile(site.output_root, "file.html", "{ hi: 4 }\n");

    try site.source_root.writeFile(.{ .sub_path = "dep.md", .data = "{ hi: 5 }<xml/>" });
    try test_run_loop.loopOnce();
    try expectFile(site.output_root, "dep.html", "<xml/>\n");
    try expectFile(site.output_root, "file.html", "{ hi: 5 }\n");
}

test "add a file for a markdown rule without a markdown extension => jay shows an error" {
    var test_run_loop = try TestRunLoop.init(.{ .markdown_patterns = &.{"*"} });
    defer test_run_loop.deinit();
    const site = test_run_loop.test_site.site;

    try site.source_root.writeFile(.{ .sub_path = "file.txt", .data = "{}<html/>" });
    try test_run_loop.loopOnce();
    try expectFile(site.output_root, "file.html", "<html/>\n");
    try std.testing.expectEqualStrings(
        \\One of the pages for a markdown rule does not have a
        \\markdown extension:
        \\
        \\  file.txt
        \\
        \\Maybe the file is in the wrong directory? If it really
        \\contains markdown, consider renaming the file to:
        \\
        \\  file.md
        \\
    , test_run_loop.output());

    // Rename the file to have a .md extension => jay marks the problem fixed.
    try site.source_root.rename("file.txt", "file.md");
    try test_run_loop.loopOnce();
    try std.testing.expectEqualStrings("", test_run_loop.output());
}

fn expectFile(dir: std.fs.Dir, path: []const u8, expected: []const u8) !void {
    var buf: [1024]u8 = undefined;
    const contents = try dir.readFile(path, &buf);
    try std.testing.expectEqualStrings(expected, contents);
}

fn expectNoFile(dir: std.fs.Dir, path: []const u8) !void {
    _ = dir.statFile(path) catch |err| {
        if (err == error.FileNotFound) return else return err;
    };
    try std.testing.expect(false);
}

const TestRunLoop = struct {
    const TestSite = @import("site.zig").TestSite;

    allocator: std.mem.Allocator,
    test_site: *TestSite,
    watcher: *Watcher,
    run_loop: *RunLoop,
    error_buf: std.BoundedArray(u8, 1024),

    fn init(config: TestSite.Config) !TestRunLoop {
        const allocator = std.testing.allocator;
        const test_site = try allocator.create(TestSite);
        test_site.* = try TestSite.init(config);
        const watcher = try allocator.create(Watcher);
        watcher.* = try Watcher.init(gpa, try test_site.site.openSourceRoot(.{}));
        const run_loop = try allocator.create(RunLoop);
        run_loop.* = try RunLoop.init(test_site.site, watcher, false);
        return .{
            .allocator = allocator,
            .test_site = test_site,
            .watcher = watcher,
            .run_loop = run_loop,
            .error_buf = try std.BoundedArray(u8, 1024).init(0),
        };
    }

    fn deinit(self: *TestRunLoop) void {
        self.watcher.deinit();
        self.test_site.deinit();
        self.allocator.destroy(self.watcher);
        self.allocator.destroy(self.run_loop);
        self.allocator.destroy(self.test_site);
    }

    fn loopOnce(self: *TestRunLoop) !void {
        self.error_buf.len = 0;
        try self.run_loop.loopOnce(self.error_buf.writer());
    }

    fn output(self: *TestRunLoop) []const u8 {
        const clearScreenEscape = "\x1b[2J";
        const slice = self.error_buf.constSlice();
        if (std.mem.startsWith(u8, slice, clearScreenEscape)) {
            return slice[clearScreenEscape.len..];
        } else {
            return slice;
        }
    }
};
