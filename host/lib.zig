const std = @import("std");
const builtin = @import("builtin");
const RocStr = @import("roc/str.zig").RocStr;
const RocList = @import("roc/list.zig").RocList;
const Site = @import("site.zig").Site;
const glob = @import("glob.zig");
const fail = @import("fail.zig");
const platform = @import("platform.zig");
const bootstrap = @import("bootstrap.zig").bootstrap;
const scan = @import("scan.zig").scan;
const generate = @import("generate.zig").generate;
const util = @import("util.zig");

const output_root = "output";

// The platform code uses 'crash' to 'throw' an error to the host in certain
// situations. We can kind of get away with it because compile-time and
// runtime are essentially the same time for this program, and so runtime
// errors have fewer downsides then they might have in other platforms.
//
// To distinguish platform panics from user panics, we prefix platform panics
// with a ridiculous string that hopefully never will attempt to copy.
const panic_prefix = "@$%^&.jayerror*";
pub fn handlePanic(roc_msg: *RocStr, tag_id: u32) void {
    const msg = roc_msg.asSlice();
    if (!std.mem.startsWith(u8, msg, panic_prefix)) {
        fail.prettily(
            \\
            \\Roc crashed with the following error:
            \\MSG:{s}
            \\TAG:{d}
            \\
            \\Shutting down
            \\
        , .{ msg, tag_id }) catch {};
        std.process.exit(1);
    }

    const code = msg[panic_prefix.len];
    const details = msg[panic_prefix.len + 2 ..];
    switch (code) {
        '0' => {
            fail.prettily(
                \\I ran into an error attempting to decode the following metadata:
                \\
                \\{s}
                \\
            , .{details}) catch {};
            std.process.exit(1);
        },
        '1' => {
            fail.prettily(
                \\I ran into an error attempting to decode the following attributes:
                \\
                \\{s}
                \\
            , .{details}) catch {};
            std.process.exit(1);
        },
        else => {
            fail.prettily("Unknown panic error code: {d}", .{code}) catch {};
            std.process.exit(1);
        },
    }
}

pub fn run(gpa: *std.heap.GeneralPurposeAllocator(.{}), site: *Site) !void {
    // (1) Call platform to get page rules.
    var roc_rules = RocList.empty();
    platform.roc__mainForHost_1_exposed_generic(&roc_rules, &void{});
    site.rules = try rocListMapToOwnedSlice(
        platform.Rule,
        Site.Rule,
        rocPagesToRule,
        site.arena.allocator(),
        roc_rules,
    );

    // (2) Scan the project to find all the source files.
    if (site.rules.len == 1 and site.rules[0].processing == .bootstrap) {
        try bootstrap(site, output_root);
    } else {
        try scan(gpa.allocator(), site, output_root);
    }

    // (3) Generate output files.
    try generate(gpa.allocator(), site, output_root);
}

fn rocPagesToRule(allocator: std.mem.Allocator, pages: platform.Rule) !Site.Rule {
    return .{
        .patterns = try rocListMapToOwnedSlice(
            RocStr,
            []const u8,
            fromRocStr,
            allocator,
            pages.patterns,
        ),
        .replaceTags = try rocListMapToOwnedSlice(
            RocStr,
            []const u8,
            fromRocStr,
            allocator,
            pages.replaceTags,
        ),
        .processing = pages.processing,
        .pages = std.ArrayList(Site.Page).init(allocator),
    };
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
    site: *Site,
    roc_pattern: *RocStr,
) !RocList {
    const pattern = roc_pattern.asSlice();
    var results = std.ArrayList(platform.Page).init(allocator);
    for (site.rules, 0..) |rule, rule_index| {
        for (rule.pages.items) |page| {
            if (glob.match(pattern, page.output_path[1..])) {
                try results.append(platform.Page{
                    .meta = RocList.fromSlice(u8, page.frontmatter, false),
                    .path = RocStr.fromSlice(util.formatPathForPlatform(page.output_path)),
                    .tags = RocList.empty(),
                    .len = 0,
                    .ruleIndex = @as(u32, @intCast(rule_index)),
                });
            }
        }
    }
    return RocList.fromSlice(platform.Page, try results.toOwnedSlice(), true);
}
