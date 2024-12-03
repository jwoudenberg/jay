const std = @import("std");
const builtin = @import("builtin");
const RocStr = @import("roc/str.zig").RocStr;
const RocList = @import("roc/list.zig").RocList;
const Path = @import("path.zig").Path;
const fail = @import("fail.zig");
const Site = @import("site.zig").Site;
const Watcher = @import("watch.zig").Watcher(Path, Path.bytes);
const glob = @import("glob.zig");
const serve = @import("serve.zig").serve;
const platform = @import("platform.zig").platform;
const bootstrap = @import("bootstrap.zig").bootstrap;
const scan = @import("scan.zig");
const WorkQueue = @import("work.zig").WorkQueue;
const generate = @import("generate.zig").generate;

pub fn main() void {
    if (run()) {} else |err| {
        fail.crudely(err, @errorReturnTrace());
    }
}

var global_site: Site = undefined;
var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
const gpa = gpa_state.allocator();

export fn roc_fx_list(pattern: *RocStr) callconv(.C) RocList {
    if (platform.getPagesMatchingPattern(gpa, &global_site, pattern)) |results| {
        return results;
    } else |err| {
        fail.crudely(err, @errorReturnTrace());
    }
}

pub fn run() !void {
    var args = std.process.args();
    const argv0 = args.next() orelse return error.EmptyArgv;

    // (1) Construct Site struct
    var paths = Path.Registry.init(gpa);
    defer paths.deinit();
    global_site = try Site.init(gpa, argv0, "output", &paths);
    defer global_site.deinit();
    var site = &global_site;

    // (2) Call platform to get page rules.
    const should_bootstrap = try platform.getRules(gpa, site);

    // (3) Scan the project to find all the source files and generate site.
    var work = WorkQueue.init(gpa);
    defer work.deinit();
    var watcher = try Watcher.init(gpa, try site.openSourceRoot(.{}));
    defer watcher.deinit();

    if (site.rules.len == 0 and should_bootstrap) {
        try bootstrap(gpa, &paths, site, &watcher, &work);
    } else {
        // Queue a job to scan the root source directory. This will result in
        // the entire project getting scanned and output generated.
        try work.push(.{ .scan_dir = try paths.intern("") });
    }
    try clearOutputDir(site);
    try doWork(gpa, &paths, site, &watcher, &work);

    // (4) Serve the output files.
    // TODO: handle thread failures.
    const thread = try std.Thread.spawn(.{}, serve, .{ &paths, site });
    thread.detach();

    // (5) Watch for changes.
    while (true) {
        while (try watcher.next_wait(50)) |change| {
            // TODO: queue work.
            std.debug.print("{any}\n", .{change});
            // Cases to handle:
            // - Known file/dir changed
            //   - queue path scan
            // - Unknown file/dir changed
            //   - check if path exists (to avoid interning temporary paths)
            //   - check if path is not ignored
            //   - queue path scan
            // - build.roc changed
            //   - queue rebuild
            // - watcher reports missed events
            //   - queue path scan for project root (i.e., rescan everything)
        }
        // No new events in the last watch period, so filesystem changes
        // have settled.
        try doWork(gpa, &paths, site, &watcher, &work);
    }
}

pub fn clearOutputDir(site: *Site) !void {
    var source_root = try site.openSourceRoot(.{ .iterate = true });
    defer source_root.close();

    source_root.deleteTree(site.output_root) catch |err| {
        if (err != error.NotDir) {
            return err;
        }
    };
    try source_root.makeDir(site.output_root);
}

pub fn doWork(
    base_allocator: std.mem.Allocator,
    paths: *Path.Registry,
    site: *Site,
    watcher: *Watcher,
    work: *WorkQueue,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(base_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var source_root = try site.openSourceRoot(.{ .iterate = true });
    defer source_root.close();

    var output_dir = try source_root.openDir(site.output_root, .{});
    defer output_dir.close();

    while (work.pop()) |job| {
        switch (job) {
            .scan_file => {
                try scan.scanFile(arena, work, site, source_root, job.scan_file);
            },
            .generate_file => {
                const page = site.getPage(job.generate_file) orelse return error.CantGenerateMissingPage;
                try generate(arena, source_root, output_dir, page);
            },
            .scan_dir => {
                try scan.scanDir(
                    work,
                    paths,
                    site,
                    watcher,
                    source_root,
                    job.scan_dir,
                );
            },
        }
        _ = arena_state.reset(.retain_capacity);
    }
}
