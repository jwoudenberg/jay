// Contains the main data structure the host code is built around.

const std = @import("std");
const fail = @import("fail.zig");
const mime = @import("mime");

pub const Site = struct {
    // The allocator that should be used for content of the struct.
    arena_state: std.heap.ArenaAllocator,
    // Absolute path of the directory containing the static site project.
    source_root: std.fs.Dir,
    // basename of the .roc file we're currently running.
    roc_main: []const u8,
    // The page-construction rules defined in the .roc file we're running.
    rules: []Rule,
    // The non-ignored source files in project directory.
    pages: std.ArrayListUnmanaged(Page),

    pub fn init(base_allocator: std.mem.Allocator, argv0: []const u8) !Site {
        var arena_state = std.heap.ArenaAllocator.init(base_allocator);
        const arena = arena_state.allocator();
        const argv0_abs = try std.fs.cwd().realpathAlloc(arena, argv0);
        const source_root_path = std.fs.path.dirname(argv0_abs) orelse "/";
        const source_root = std.fs.cwd().openDir(source_root_path, .{ .iterate = true }) catch |err| {
            try fail.prettily("Cannot access directory containing {s}: '{}'\n", .{ source_root_path, err });
        };

        return Site{
            .arena_state = arena_state,
            .source_root = source_root,
            .roc_main = std.fs.path.basename(argv0_abs),
            .rules = &.{},
            .pages = try std.ArrayListUnmanaged(Page).initCapacity(arena, 0),
        };
    }

    pub fn allocator(self: *Site) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    pub fn deinit(self: *Site) void {
        self.source_root.close();
        self.arena_state.deinit();
    }

    pub const Rule = struct {
        patterns: []const []const u8,
        replaceTags: []const []const u8,
        processing: Processing,
    };

    pub const Page = struct {
        rule_index: usize,
        mime_type: mime.Type,
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
