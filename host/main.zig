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
    // (1) Construct Site struct
    var strs = try Str.Registry.init(gpa);
    defer strs.deinit();
    var site = try createSite(strs);
    defer site.deinit();

    // (2) Call platform to get page rules.
    const should_bootstrap = try platform.getRules(gpa, &site);

    // (3) Scan the project to find all the source files and generate site.
    var watcher = try Watcher.init(gpa, try site.openSourceRoot(.{}));
    defer watcher.deinit();

    if (site.rules.len == 0 and should_bootstrap) {
        try bootstrap(gpa, &site);
    }

    // Scan the source directory to build a list of pages and then generate
    // outputs for these pages.
    try scanRecursively(gpa, &site, &watcher, try site.strs.intern(""));
    try site.scanAndGeneratePages();

    // (4) Serve the output files.
    // TODO: handle thread failures.
    const thread = try std.Thread.spawn(.{}, serve, .{&site});
    thread.detach();

    // (5) Watch for changes.
    var stdout = std.io.getStdOut().writer();
    while (true) {
        try site.errors.print(&stdout);
        while (try watcher.next_wait(50)) |change| {
            try handle_change(&site, &watcher, change);
        }
        // No new events in the last watch period, so filesystem changes
        // have settled.
        try site.scanAndGeneratePages();
    }
}

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
