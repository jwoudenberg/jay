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

fn run() !void {
    var args = std.process.args();
    const argv0 = args.next() orelse return error.EmptyArgv;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // (1) Construct Site struct
    var strs = Str.Registry.init(gpa);
    defer strs.deinit();
    global_site = try Site.init(gpa, std.fs.cwd(), argv0, "output", &strs);
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
        try bootstrap(gpa, &strs, site, &watcher, &work);
    } else {
        // Queue a job to scan the root source directory. This will result in
        // the entire project getting scanned and output generated.
        try work.push(.{ .scan_dir = try strs.intern("") });
    }

    var source_root = try site.openSourceRoot(.{ .iterate = true });
    defer source_root.close();
    try clearOutputDir(source_root, site);
    try doWork(gpa, &strs, site, &watcher, &work);

    // (4) Serve the output files.
    // TODO: handle thread failures.
    const thread = try std.Thread.spawn(.{}, serve, .{ &strs, site });
    thread.detach();

    // (5) Watch for changes.
    while (true) {
        _ = arena_state.reset(.retain_capacity);
        while (try watcher.next_wait(50)) |change| {
            try handle_change(&strs, &work, change);
        }
        // No new events in the last watch period, so filesystem changes
        // have settled.
        try doWork(arena, &strs, site, &watcher, &work);
    }
}

fn handle_change(
    strs: *Str.Registry,
    work: *WorkQueue,
    change: Watcher.Change,
) !void {
    // TODO: queue work.
    // Cases to handle:
    // - Known file/dir changed
    //   - queue path scan
    // - Unknown file/dir changed
    //   - check if path exists (to avoid interning temporary strs)
    //   - check if path is not ignored
    //   - queue path scan
    // - build.roc changed
    //   - queue rebuild
    // - watcher reports missed events
    //   - queue path scan for project root (i.e., rescan everything)
    switch (change) {
        .changes_missed => {
            std.debug.print("TODO: rescan entire project", .{});
        },
        .dir_changed => |entry| {
            std.debug.print(
                "TODO: re-scan dir {s}/{s}\n",
                .{ entry.dir.bytes(), entry.file_name },
            );
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
            if (strs.get(path_bytes)) |path| {
                try work.push(.{ .scan_file = path });
            } else {
                std.debug.print("TODO: scan new file {s}\n", .{path_bytes});
            }
        },
    }
}

fn clearOutputDir(source_root: std.fs.Dir, site: *Site) !void {
    source_root.deleteTree(site.output_root) catch |err| {
        if (err != error.NotDir) {
            return err;
        }
    };
    try source_root.makeDir(site.output_root);
}

fn doWork(
    arena: std.mem.Allocator,
    strs: *Str.Registry,
    site: *Site,
    watcher: *Watcher,
    work: *WorkQueue,
) !void {
    var source_root = try site.openSourceRoot(.{ .iterate = true });
    defer source_root.close();

    var output_dir = try source_root.openDir(site.output_root, .{});
    defer output_dir.close();

    while (work.pop()) |job| {
        switch (job) {
            .scan_file => {
                try scan.scanFile(work, site, job.scan_file);
            },
            .generate_file => {
                const page = site.getPage(job.generate_file) orelse return error.CantGenerateMissingPage;
                try generate(arena, source_root, output_dir, page);
            },
            .scan_dir => {
                try scan.scanDir(
                    work,
                    strs,
                    site,
                    watcher,
                    source_root,
                    job.scan_dir,
                );
            },
        }
    }
}
