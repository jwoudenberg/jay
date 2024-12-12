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
        try site.scanAndGeneratePages();

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
        try self.site.scanAndGeneratePages();
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

test "when adding a new source file we generate an output file for it" {
    var test_run_loop = try TestRunLoop.init(.{ .markdown_patterns = &.{"*.md"} });
    defer test_run_loop.deinit();
    const source_root = test_run_loop.test_site.site.source_root;
    const output_root = test_run_loop.test_site.site.output_root;

    try source_root.writeFile(.{ .sub_path = "file.md", .data = "{}<html/>" });
    try test_run_loop.loopOnce();
    try std.testing.expectEqualStrings("\x1b[2J", test_run_loop.output());
    try expectFile(output_root, "file.html", "<html/>\n");
}

fn expectFile(dir: std.fs.Dir, path: []const u8, expected: []const u8) !void {
    var buf: [1024]u8 = undefined;
    const contents = try dir.readFile(path, &buf);
    try std.testing.expectEqualStrings(expected, contents);
}

const TestRunLoop = struct {
    const TestSite = @import("site.zig").TestSite;

    allocator: std.mem.Allocator,
    test_site: *TestSite,
    watcher: *Watcher,
    run_loop: *RunLoop,
    error_buf: std.BoundedArray(u8, 256),

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
            .error_buf = try std.BoundedArray(u8, 256).init(0),
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
        return self.error_buf.constSlice();
    }
};
