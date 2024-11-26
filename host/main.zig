const std = @import("std");
const builtin = @import("builtin");
const RocStr = @import("roc/str.zig").RocStr;
const RocList = @import("roc/list.zig").RocList;
const Path = @import("path.zig").Path;
const fail = @import("fail.zig");
const Site = @import("site.zig").Site;
const Watcher = @import("watch.zig").Watcher;
const glob = @import("glob.zig");
const serve = @import("serve.zig").serve;
const platform = @import("platform.zig");
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
    if (getPagesMatchingPattern(gpa, pattern)) |results| {
        return results;
    } else |err| {
        fail.crudely(err, @errorReturnTrace());
    }
}

pub fn run() !void {
    var args = std.process.args();
    const argv0 = args.next() orelse return error.EmptyArgv;

    // (1) Call platform to get page rules.
    var roc_rules = RocList.empty();
    platform.roc__mainForHost_1_exposed_generic(&roc_rules, &void{});

    // (2) Construct Site struct
    global_site = try Site.init(gpa, argv0, "output");
    defer global_site.deinit();
    var paths = Path.Registry.init(gpa);
    var site = &global_site;
    var should_bootstrap = false;
    var rules = std.ArrayList(Site.Rule).init(gpa);
    errdefer rules.deinit();
    var ignore_patterns = std.ArrayList([]const u8).fromOwnedSlice(gpa, try gpa.dupe([]const u8, site.ignore_patterns));
    errdefer ignore_patterns.deinit();
    var roc_rule_iterator = platform.RocListIterator(platform.Rule).init(roc_rules);
    const arena = site.allocator();
    while (roc_rule_iterator.next()) |platform_rule| {
        switch (platform_rule.processing) {
            .none, .xml, .markdown => {
                const rule = .{
                    .patterns = try rocListMapToOwnedSlice(
                        RocStr,
                        []const u8,
                        fromRocStr,
                        arena,
                        platform_rule.patterns,
                    ),
                    .replace_tags = try rocListMapToOwnedSlice(
                        RocStr,
                        []const u8,
                        fromRocStr,
                        arena,
                        platform_rule.replace_tags,
                    ),
                    .processing = @as(Site.Processing, @enumFromInt(@intFromEnum(platform_rule.processing))),
                };
                try rules.append(rule);
            },
            .ignore => {
                const patterns = try rocListMapToOwnedSlice(
                    RocStr,
                    []const u8,
                    fromRocStr,
                    arena,
                    platform_rule.patterns,
                );
                try ignore_patterns.appendSlice(patterns);
            },
            .bootstrap => {
                should_bootstrap = true;
            },
        }
    }
    site.rules = try arena.dupe(Site.Rule, try rules.toOwnedSlice());
    site.ignore_patterns = try arena.dupe([]const u8, try ignore_patterns.toOwnedSlice());

    // (3) Scan the project to find all the source files and generate site.
    var work = WorkQueue.init(gpa);
    defer work.deinit();
    var watcher = try Watcher.init(gpa, &paths, try site.openSourceRoot(.{}));
    defer watcher.deinit();

    if (site.rules.len == 0 and should_bootstrap) {
        try bootstrap(gpa, &paths, site, &watcher, &work);
    } else {
        // Queue a job to scan the root source directory. This will result in
        // the entire project getting scanned and output generated.
        try work.push(.{ .scan_dir = try paths.intern("") });
        try clearOutputDir(site);
        try doWork(gpa, &paths, site, &watcher, &work);
    }

    // (4) Serve the output files.
    // TODO: handle thread failures.
    const thread = try std.Thread.spawn(.{}, serve, .{ &paths, site });
    thread.detach();

    // (5) Watch for changes.
    while (true) {
        const change = try watcher.next();
        if (change.is_dir) {
            try work.push(.{ .scan_dir = change.path });
        } else {
            try work.push(.{ .scan_file = change.path });
        }
        try doWork(gpa, &paths, site, &watcher, &work);
    }
}

fn fromRocStr(allocator: std.mem.Allocator, roc_pattern: RocStr) ![]const u8 {
    return try allocator.dupe(u8, roc_pattern.asSlice());
}

fn rocListMapToOwnedSlice(
    comptime T: type,
    comptime O: type,
    comptime map: fn (allocator: std.mem.Allocator, elem: T) anyerror!O,
    allocator: std.mem.Allocator,
    list: RocList,
) ![]O {
    const len = list.len();
    if (len == 0) return allocator.alloc(O, 0);
    const elements = list.elements(T) orelse return error.RocListUnexpectedlyEmpty;
    const slice = try allocator.alloc(O, len);
    for (elements, 0..len) |element, index| {
        slice[index] = try map(allocator, element);
    }
    return slice;
}

pub fn getPagesMatchingPattern(
    allocator: std.mem.Allocator,
    roc_pattern: *RocStr,
) !RocList {
    const pattern = roc_pattern.asSlice();
    var results = std.ArrayList(platform.Page).init(allocator);
    var page_iterator = global_site.iterator();
    while (page_iterator.next()) |page| {
        if (glob.match(pattern, page.source_path.bytes())) {
            try results.append(platform.Page{
                .meta = RocList.fromSlice(u8, page.frontmatter, false),
                .path = RocStr.fromSlice(page.web_path.bytes()),
                .tags = RocList.empty(),
                .len = 0,
                .ruleIndex = @as(u32, @intCast(page.rule_index)),
            });
        }
    }
    return RocList.fromSlice(platform.Page, try results.toOwnedSlice(), true);
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

    var unmatched_paths = std.ArrayList(Path).init(arena);
    defer unmatched_paths.deinit();

    var source_root = try site.openSourceRoot(.{ .iterate = true });
    defer source_root.close();

    var output_dir = try source_root.openDir(site.output_root, .{});
    defer output_dir.close();

    while (work.pop()) |job| {
        switch (job) {
            .scan_file => {
                const page = try scan.scanFile(
                    arena,
                    paths,
                    site,
                    source_root,
                    job.scan_file,
                    &unmatched_paths,
                );
                try work.push(.{ .generate_file = page.source_path });
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

    if (unmatched_paths.items.len > 0) {
        try unmatchedSourceFileError(try unmatched_paths.toOwnedSlice());
    }
}

fn unmatchedSourceFileError(unmatched_paths: []Path) !noreturn {
    if (builtin.is_test) return error.PrettyError;

    const stderr = std.io.getStdErr().writer();

    try stderr.print(
        \\Some source files are not matched by any rule.
        \\If you don't mean to include these in your site,
        \\you can ignore them like this:
        \\
        \\    Site.ignore
        \\        [
        \\
    , .{});
    for (unmatched_paths) |path| {
        try stderr.print("            \"{s}\",\n", .{path.bytes()});
    }
    try stderr.print(
        \\        ]
    , .{});

    return error.PrettyError;
}
