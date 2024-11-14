const std = @import("std");
const builtin = @import("builtin");
const RocStr = @import("roc/str.zig").RocStr;
const RocList = @import("roc/list.zig").RocList;
const fail = @import("fail.zig");
const Site = @import("site.zig").Site;
const glob = @import("glob.zig");
const serve = @import("serve.zig").serve;
const platform = @import("platform.zig");
const bootstrap = @import("bootstrap.zig").bootstrap;
const scan = @import("scan.zig").scan;
const generate = @import("generate.zig").generate;

pub fn main() void {
    if (run()) {} else |err| {
        fail.crudely(err);
    }
}

var site: Site = undefined;
var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
const gpa = gpa_state.allocator();

export fn roc_fx_list(pattern: *RocStr) callconv(.C) RocList {
    if (getPagesMatchingPattern(gpa, pattern)) |results| {
        return results;
    } else |err| {
        fail.crudely(err);
    }
}

pub fn run() !void {
    var args = std.process.args();
    const argv0 = args.next() orelse return error.EmptyArgv;
    var timer = try std.time.Timer.start();

    // (1) Call platform to get page rules.
    var roc_rules = RocList.empty();
    platform.roc__mainForHost_1_exposed_generic(&roc_rules, &void{});

    // (2) Construct Site struct
    site = try Site.init(gpa, argv0, "output");
    defer site.deinit();
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
                    .replaceTags = try rocListMapToOwnedSlice(
                        RocStr,
                        []const u8,
                        fromRocStr,
                        arena,
                        platform_rule.replaceTags,
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

    // (3) Scan the project to find all the source files.
    if (site.rules.len == 1 and should_bootstrap) {
        try bootstrap(gpa, &site);
    } else {
        try scan(gpa, &site);
    }

    // (4) Generate output files.
    try generate(gpa, &site);

    const stdout = std.io.getStdOut().writer();
    try stdout.print("Generated site in {d}ms\n", .{timer.read() / 1_000_000});

    // (5) Serve the output files.
    try serve(gpa, &site);
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
    var page_iterator = site.pages.iterator(0);
    while (page_iterator.next()) |page| {
        if (glob.match(pattern, page.source_path)) {
            try results.append(platform.Page{
                .meta = RocList.fromSlice(u8, page.frontmatter, false),
                .path = RocStr.fromSlice(page.web_path),
                .tags = RocList.empty(),
                .len = 0,
                .ruleIndex = @as(u32, @intCast(page.rule_index)),
            });
        }
    }
    if (results.items.len == 0) {
        try fail.prettily("Pattern '{s}' did not match any files", .{pattern});
    }
    return RocList.fromSlice(platform.Page, try results.toOwnedSlice(), true);
}
