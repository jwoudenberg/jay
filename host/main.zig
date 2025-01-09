const std = @import("std");
const builtin = @import("builtin");
const Args = @import("argparse.zig").Args;
const RocStr = @import("roc/str.zig").RocStr;
const RocList = @import("roc/list.zig").RocList;
const Str = @import("str.zig").Str;
const fail = @import("fail.zig");
const Site = @import("site.zig").Site;
const Watcher = @import("watch.zig").Watcher;
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

fn run_prod(gpa: std.mem.Allocator, argv0: []const u8, output_path: []const u8) !void {
    var strs = try Str.Registry.init(gpa);
    defer strs.deinit();
    var output_dir = try std.fs.cwd().makeOpenPath(output_path, .{});
    defer output_dir.close();
    var site = try createSite(gpa, argv0, output_dir, strs);
    defer site.source_root.close();
    defer site.output_root.close();
    defer site.deinit();
    const should_bootstrap = try platform.getRules(gpa, &site);
    if (should_bootstrap) try bootstrap(gpa, &site);
    var watcher = NoOpWatcher{};
    try scanRecursively(gpa, &site, &watcher, "");
    if (site.errors.has_errors()) {
        var stderr = std.io.getStdErr().writer();
        try site.errors.print(&stderr);
        std.process.exit(1);
    } else {
        try site.generatePages();
    }
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
    const cwd_path = try std.posix.getcwd(&buf);
    const roc_main_abs = try std.fs.path.resolve(gpa, &.{ cwd_path, argv0 });
    defer gpa.free(roc_main_abs);
    const source_root_path = std.fs.path.dirname(roc_main_abs) orelse "/";

    var cache_dir = try cacheDir(std.fs.cwd(), roc_main_abs, envMap);
    defer cache_dir.close();
    var site = try createSite(gpa, argv0, cache_dir, strs);
    defer site.source_root.close();
    defer site.output_root.close();
    defer site.deinit();

    const should_bootstrap = try platform.getRules(gpa, &site);

    const watcher = try Watcher.init(gpa, source_root_path);
    defer watcher.deinit();
    var runLoop = try RunLoop.init(gpa, &site, watcher, should_bootstrap);

    try spawnServer(&site);

    var stdout = std.io.getStdOut().writer();
    while (true) try runLoop.loopOnce(&stdout);
}

// The core watch/generate loop of the app extracted in a format that I can
// relatively easily write tests for.
pub const RunLoop = struct {
    gpa: std.mem.Allocator,
    site: *Site,
    watcher: *Watcher,

    pub fn init(
        gpa: std.mem.Allocator,
        site: *Site,
        watcher: *Watcher,
        should_bootstrap: bool,
    ) !RunLoop {
        if (site.rules.len == 0 and should_bootstrap) {
            try bootstrap(gpa, site);
        }

        try scanRecursively(gpa, site, watcher, "");
        try site.generatePages();

        return .{
            .gpa = gpa,
            .site = site,
            .watcher = watcher,
        };
    }

    pub fn loopOnce(self: *RunLoop, writer: anytype) !void {
        while (try self.watcher.nextWait(50)) |change| {
            try handleChange(self.gpa, self.site, self.watcher, change);
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
    output_dir: std.fs.Dir,
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

    // Produce output in a subdirectory with a somewhat unique name. This is a
    // directory we can wipe without worrying we might `rm -r /`.
    const output_root_dirname = "jay-output";
    output_dir.deleteTree(output_root_dirname) catch |err| if (err != error.NotDir) return err;
    const output_root = try output_dir.makeOpenPath(output_root_dirname, .{});

    return Site.init(gpa, source_root, roc_main, output_root, strs);
}

// Get a unique cache dir for each Jay-project.
fn cacheDir(
    cwd: std.fs.Dir,
    roc_main_abs: []const u8,
    envMap: EnvMap,
) !std.fs.Dir {
    var jay_cache_dir = blk: {
        if (envMap.xdg_cache_home) |xdg_cache_home| {
            var cache_dir = try cwd.makeOpenPath(xdg_cache_home, .{});
            defer cache_dir.close();
            break :blk try cache_dir.makeOpenPath("jay", .{});
        }
        if (envMap.home) |home_path| {
            var home_dir = try cwd.makeOpenPath(home_path, .{});
            defer home_dir.close();
            break :blk try home_dir.makeOpenPath(".cache/jay", .{});
        }
        try fail.prettily(
            \\I don't know where to generate temporary files.
            \\
            \\Normally I use $XDG_CACHE_HOME or $HOME to find a place where I can
            \\create a cache directory, but both are unset.
            \\
        , .{});
    };
    defer jay_cache_dir.close();

    // In the hypothetical situation someone runs multiple instances of jay
    // in parallel, they should not to clobber each other's output directories.
    // We create a subdirectory for each.
    var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const project_dir_hash = std.hash.Wyhash.hash(0, roc_main_abs);
    const project_dir_name = try std.fmt.bufPrint(&buf, "{}", .{project_dir_hash});
    return jay_cache_dir.makeOpenPath(project_dir_name, .{});
}

test cacheDir {
    var tmpdir = std.testing.tmpDir(.{});
    defer tmpdir.cleanup();

    // Create directory in $XDG_CACHE_HOME if it is set.
    {
        var cache_dir = try cacheDir(
            tmpdir.dir,
            "/project/build.roc",
            .{ .xdg_cache_home = "cache", .home = "home" },
        );
        defer cache_dir.close();
        try cache_dir.writeFile(.{ .sub_path = "test", .data = "" });
        try tmpdir.dir.access("cache/jay/11302437488756564278/test", .{});
    }

    // Create directory in $HOME when it is set but $XDG_CACHE_HOME is not.
    {
        var cache_dir = try cacheDir(
            tmpdir.dir,
            "/project/build.roc",
            .{ .xdg_cache_home = null, .home = "home" },
        );
        defer cache_dir.close();
        try cache_dir.writeFile(.{ .sub_path = "test", .data = "" });
        try tmpdir.dir.access("home/.cache/jay/11302437488756564278/test", .{});
    }

    // Return error if $HOME and $XDG_CACHE_HOME are both unset.
    try std.testing.expectError(
        error.PrettyError,
        cacheDir(
            tmpdir.dir,
            "/project/build.roc",
            .{ .xdg_cache_home = null, .home = null },
        ),
    );

    // Open existing directory if cache path already exists
    {
        const cache_path = "cache/jay/11302437488756564278";
        var cache_dir_orig = try tmpdir.dir.makeOpenPath(cache_path, .{});
        defer cache_dir_orig.close();

        var cache_dir = try cacheDir(
            tmpdir.dir,
            "/project/build.roc",
            .{ .xdg_cache_home = "cache", .home = null },
        );
        defer cache_dir.close();
        try cache_dir.writeFile(.{ .sub_path = "test", .data = "" });

        try cache_dir_orig.access("test", .{});
    }
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

fn getOptEnvVar(gpa: std.mem.Allocator, key: []const u8) !?[]const u8 {
    return std.process.getEnvVarOwned(gpa, key) catch |err| {
        if (err == error.EnvironmentVariableNotFound) {
            return null;
        } else {
            return err;
        }
    };
}

pub fn handleChange(
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
                "",
            );
        },
        .path_changed => |entry| {
            var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
            const path_bytes = if (entry.dir.bytes().len == 0)
                entry.file_name
            else
                try std.fmt.bufPrint(
                    &buf,
                    "{s}/{s}",
                    .{ entry.dir.bytes(), entry.file_name },
                );
            try scanRecursively(gpa, site, watcher, path_bytes);

            const path = site.strs.get(path_bytes) orelse return;
            if (path == site.roc_main) {
                rebuildRocMain(gpa) catch |err| {
                    // In case of a file busy error the write to roc main might
                    // still be ongoing. There will be another event when it
                    // finishes, we can try to execv again then.
                    if (err != error.FileBusy) return err;
                };
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
