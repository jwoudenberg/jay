const std = @import("std");
const builtin = @import("builtin");
const Args = @import("argparse.zig").Args;
const RocStr = @import("roc/str.zig").RocStr;
const RocList = @import("roc/list.zig").RocList;
const Str = @import("str.zig").Str;
const fail = @import("fail.zig");
const Site = @import("site.zig").Site;
const Watcher = @import("watch.zig").Watcher(Str, Str.bytes);
const spawnServer = @import("serve.zig").spawnServer;
const platform = @import("platform.zig").platform;
const bootstrap = @import("bootstrap.zig").bootstrap;
const scanRecursively = @import("scan.zig").scanRecursively;

pub fn main() void {
    run() catch |err| fail.crudely(err, @errorReturnTrace());
}

fn run() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_state.allocator();

    var strs = try Str.Registry.init(gpa);
    defer strs.deinit();
    var envMap = try EnvMap.init(gpa);
    defer envMap.deinit();
    var args = std.process.args();
    const parsed = try Args.parse(&args);

    switch (parsed) {
        .run_dev_mode => try run_dev(
            gpa,
            parsed.run_dev_mode.argv0,
        ),
        .run_prod_mode => try run_prod(
            gpa,
            parsed.run_prod_mode.argv0,
            parsed.run_prod_mode.output,
        ),
        .show_help => {
            var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
            const cwd = try std.posix.getcwd(&buf);
            const argv0 = try std.fs.path.relative(gpa, cwd, parsed.show_help.argv0);
            defer gpa.free(argv0);
            var stdout = std.io.getStdOut().writer();
            try stdout.print(
                \\Jay - a static site generator for Roc.
                \\
                \\./{s}
                \\    When called without arguments Jay starts in development
                \\    mode, and will start a file watcher and web server.
                \\
                \\./{s} prod [path]
                \\    Run Jay in production mode and generate the site files
                \\    at the specified path.
                \\
                \\./{s} help
                \\    Show this help text.
                \\
            , .{ argv0, argv0, argv0 });
        },
        .mistake_no_output_path_passed => {
            var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
            const cwd = try std.posix.getcwd(&buf);
            const argv0 = try std.fs.path.relative(
                gpa,
                cwd,
                parsed.mistake_no_output_path_passed.argv0,
            );
            defer gpa.free(argv0);
            var stderr = std.io.getStdErr().writer();
            try stderr.print(
                \\Oops, you didn't tell me where I should generate the site.
                \\
                \\To generate the site in production mode, pass me a path
                \\and I'll generate the site there:
                \\
                \\    ./{s} prod [path]
                \\
            , .{argv0});
            std.process.exit(1);
        },
        .mistake_unknown_argument => {
            var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
            const cwd = try std.posix.getcwd(&buf);
            const arg = parsed.mistake_unknown_argument.arg;
            const argv0 = try std.fs.path.relative(
                gpa,
                cwd,
                parsed.mistake_unknown_argument.argv0,
            );
            defer gpa.free(argv0);
            var stderr = std.io.getStdErr().writer();
            try stderr.print(
                \\Oops, I don't know the command '{s}'.
                \\
                \\For a list of commands I support you can run:
                \\
                \\    ./{s} help
                \\
            , .{ arg, argv0 });
            std.process.exit(1);
        },
    }
}

fn run_prod(gpa: std.mem.Allocator, argv0: []const u8, output: []const u8) !void {
    var strs = try Str.Registry.init(gpa);
    defer strs.deinit();
    var site = try createSite(gpa, argv0, output, strs);
    defer site.source_root.close();
    defer site.output_root.close();
    defer site.deinit();
    const should_bootstrap = try platform.getRules(gpa, &site);
    if (should_bootstrap) try bootstrap(gpa, &site);
    var watcher = NoOpWatcher{};
    try scanRecursively(gpa, &site, &watcher, try site.strs.intern(""));
    try site.generatePages();
    var stdout = std.io.getStdOut().writer();
    try site.errors.print(&stdout);
}

const NoOpWatcher = struct {
    pub fn watchDir(self: *NoOpWatcher, path: Str) !void {
        _ = self;
        _ = path;
    }
};

fn run_dev(gpa: std.mem.Allocator, argv0: []const u8) !void {
    var strs = try Str.Registry.init(gpa);
    defer strs.deinit();
    var envMap = try EnvMap.init(gpa);
    defer envMap.deinit();

    var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const cwd = try std.posix.getcwd(&buf);
    const roc_main_abs = try std.fs.path.resolve(gpa, &.{ cwd, argv0 });
    defer gpa.free(roc_main_abs);

    const cache_dir_path = try cacheDir(roc_main_abs, envMap, &buf);
    var site = try createSite(gpa, argv0, cache_dir_path, strs);
    defer site.source_root.close();
    defer site.output_root.close();
    defer site.deinit();

    const should_bootstrap = try platform.getRules(gpa, &site);

    var source_root = try site.openSourceRoot(.{});
    defer source_root.close();
    var watcher = try Watcher.init(gpa, source_root);
    defer watcher.deinit();
    var runLoop = try RunLoop.init(gpa, &site, &watcher, should_bootstrap);

    try spawnServer(&site);

    var stdout = std.io.getStdOut().writer();
    while (true) try runLoop.loopOnce(&stdout);
}

// The core watch/generate loop of the app extracted in a format that I can
// relatively easily write tests for.
const RunLoop = struct {
    gpa: std.mem.Allocator,
    site: *Site,
    watcher: *Watcher,

    fn init(
        gpa: std.mem.Allocator,
        site: *Site,
        watcher: *Watcher,
        should_bootstrap: bool,
    ) !RunLoop {
        if (site.rules.len == 0 and should_bootstrap) {
            try bootstrap(gpa, site);
        }

        try scanRecursively(gpa, site, watcher, try site.strs.intern(""));
        try site.generatePages();

        return .{
            .gpa = gpa,
            .site = site,
            .watcher = watcher,
        };
    }

    fn loopOnce(self: *RunLoop, writer: anytype) !void {
        while (try self.watcher.next_wait(50)) |change| {
            try handle_change(self.gpa, self.site, self.watcher, change);
        }
        // No new events in the last watch period, so filesystem changes
        // have settled.
        try self.site.generatePages();
        try self.site.errors.print(writer);
    }
};

fn createSite(
    gpa: std.mem.Allocator,
    argv0: []const u8,
    output_dir_path: []const u8,
    strs: Str.Registry,
) !Site {
    const source_root_path = std.fs.path.dirname(argv0) orelse "./";
    const roc_main = std.fs.path.basename(argv0);
    const source_root = std.fs.cwd().openDir(source_root_path, .{}) catch |err| {
        try fail.prettily(
            "Cannot access directory containing {s}: '{}'\n",
            .{ source_root_path, err },
        );
    };
    const output_dir = try openOutputDir(output_dir_path);
    return Site.init(gpa, source_root, roc_main, output_dir, strs);
}

fn cacheDir(roc_main_abs: []const u8, envMap: EnvMap, buf: []u8) ![]u8 {
    // In the hypothetical situation someone runs multiple instances of jay
    // in parallel, I'd like those not to clobber each other's output
    // directories. We create a subdirectory for each.
    const output_dir = std.hash.murmur.Murmur3_32.hash(roc_main_abs);

    if (envMap.xdg_cache_home) |xdg_cache_home| {
        return std.fmt.bufPrint(buf, "{s}/jay/{}", .{ xdg_cache_home, output_dir });
    }

    if (envMap.home) |home_dir| {
        return std.fmt.bufPrint(buf, "{s}/.cache/jay/{}", .{ home_dir, output_dir });
    }

    try fail.prettily(
        \\I don't know where to generate temporary files.
        \\
        \\Normally I use $XDG_CACHE_HOME or $HOME to find a place where I can
        \\create a cache directory, but both are unset.
        \\
    , .{});
}

test cacheDir {
    var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;

    try std.testing.expectEqualStrings(
        "/cache/jay/1289569777",
        try cacheDir(
            "/project/build.roc",
            .{ .xdg_cache_home = "/cache", .home = "/home" },
            &buf,
        ),
    );

    try std.testing.expectEqualStrings(
        "/home/.cache/jay/1289569777",
        try cacheDir(
            "/project/build.roc",
            .{ .xdg_cache_home = null, .home = "/home" },
            &buf,
        ),
    );

    try std.testing.expectError(
        error.PrettyError,
        cacheDir(
            "/project/build.roc",
            .{ .xdg_cache_home = null, .home = null },
            &buf,
        ),
    );
}

// Env variables relevant for this app.
const EnvMap = struct {
    arena_state: std.heap.ArenaAllocator = undefined,
    xdg_cache_home: ?[]const u8 = null,
    home: ?[]const u8 = null,

    fn init(gpa: std.mem.Allocator) !EnvMap {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        const arena = arena_state.allocator();
        return .{
            .arena_state = arena_state,
            .xdg_cache_home = try getOptEnvVar(arena, "XDG_CACHE_HOME"),
            .home = try getOptEnvVar(arena, "HOME"),
        };
    }

    fn deinit(self: *EnvMap) void {
        self.arena_state.deinit();
    }
};

fn openOutputDir(path: []const u8) !std.fs.Dir {
    const cwd = std.fs.cwd();
    cwd.deleteTree(path) catch |err| if (err != error.NotDir) return err;
    try cwd.makePath(path);
    return cwd.openDir(path, .{});
}

fn getOptEnvVar(gpa: std.mem.Allocator, key: []const u8) !?[]const u8 {
    return std.process.getEnvVarOwned(gpa, key) catch |err| {
        if (err == error.EnvironmentVariableNotFound) {
            return null;
        } else {
            return err;
        }
    };
}

fn handle_change(
    gpa: std.mem.Allocator,
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
            const path = try site.strs.intern(path_bytes);
            if (path == site.roc_main) {
                rebuildRocMain(gpa) catch |err| {
                    // In case of a file busy error the write to roc main might
                    // still be ongoing. There will be another event when it
                    // finishes, we can try to execv again then.
                    if (err != error.FileBusy) return err;
                };
            } else if (!Site.matchAny(site.ignore_patterns, path_bytes)) {
                try site.touchPage(path);
            }
        },
    }
}

// Restart the process based on a new site specification. It'd be
// nice to do this in a nicer way, so we can for instance carry
// over our web server thread.
fn rebuildRocMain(gpa: std.mem.Allocator) !void {
    var args = std.process.args();
    const argv0 = args.next() orelse return error.EmptyArgv;
    return std.process.execv(gpa, &.{ argv0, "--linker=legacy" });
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
        try handle_change(std.testing.allocator, site, run_loop.watcher, change);
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
    try test_run_loop.loopOnce();
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

test "add a file that does not match a pattern => jay will show an error" {
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

test "change a file but not its metadata => jay updates the file" {
    var test_run_loop = try TestRunLoop.init(.{ .markdown_patterns = &.{"*.md"} });
    defer test_run_loop.deinit();
    const site = test_run_loop.test_site.site;

    try site.source_root.writeFile(.{ .sub_path = "file.md", .data = "{ hi: 4 }<html/>" });
    try test_run_loop.loopOnce();
    try expectFile(site.output_root, "file.html", "<html/>\n");

    try site.source_root.writeFile(.{ .sub_path = "file.md", .data = "{ hi: 4 }<xml/>" });
    try test_run_loop.loopOnce();
    try expectFile(site.output_root, "file.html", "<xml/>\n");
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
    source_root: std.fs.Dir,
    test_site: *TestSite,
    watcher: *Watcher,
    run_loop: *RunLoop,
    error_buf: std.BoundedArray(u8, 1024),

    fn init(config: TestSite.Config) !TestRunLoop {
        const allocator = std.testing.allocator;
        const test_site = try allocator.create(TestSite);
        test_site.* = try TestSite.init(config);
        const watcher = try allocator.create(Watcher);
        const source_root = try test_site.site.openSourceRoot(.{});
        watcher.* = try Watcher.init(allocator, source_root);
        const run_loop = try allocator.create(RunLoop);
        run_loop.* = try RunLoop.init(allocator, test_site.site, watcher, false);
        return .{
            .allocator = allocator,
            .source_root = source_root,
            .test_site = test_site,
            .watcher = watcher,
            .run_loop = run_loop,
            .error_buf = try std.BoundedArray(u8, 1024).init(0),
        };
    }

    fn deinit(self: *TestRunLoop) void {
        self.watcher.deinit();
        self.test_site.deinit();
        self.source_root.close();
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
