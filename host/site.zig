const std = @import("std");
const fail = @import("fail.zig");

pub const Site = struct {
    arena: std.heap.ArenaAllocator,
    source_root: std.fs.Dir,
    roc_main: []const u8,
    rules: []Rule,

    pub fn init(base_allocator: std.mem.Allocator, argv0: []const u8) !Site {
        var arena = std.heap.ArenaAllocator.init(base_allocator);
        const allocator = arena.allocator();

        const argv0_abs = try std.fs.cwd().realpathAlloc(allocator, argv0);
        const source_root_path = std.fs.path.dirname(argv0_abs) orelse "/";
        const source_root = std.fs.cwd().openDir(source_root_path, .{ .iterate = true }) catch |err| {
            try fail.prettily("Cannot access directory containing {s}: '{}'\n", .{ source_root_path, err });
        };

        return Site{
            .arena = arena,
            .source_root = source_root,
            .roc_main = std.fs.path.basename(argv0_abs),
            .rules = &.{},
        };
    }

    pub fn deinit(self: *Site) void {
        self.source_root.close();
        self.arena.deinit();
    }

    pub const Rule = struct {
        patterns: []const []const u8,
        replaceTags: []const []const u8,
        processing: Processing,
        pages: std.ArrayList(Page),
    };

    pub const Page = struct {
        source_path: []const u8,
        output_path: []const u8,
        frontmatter: []const u8,
    };

    pub const Processing = enum(u8) {
        bootstrap = 0,
        ignore = 1,
        markdown = 2,
        none = 3,
        xml = 4,
    };
};
