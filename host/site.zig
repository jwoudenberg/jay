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
    // The pages in a project. Designed so a single thread can append new items
    // while multiple threads read existing items.
    pages: std.SegmentedList(Page, 0),
    // Map for efficient access to a page by its web path.
    web_paths: std.StringHashMapUnmanaged(PageIndex),

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
            .pages = std.SegmentedList(Page, 0){},
            .web_paths = std.StringHashMapUnmanaged(PageIndex){},
        };
    }

    pub fn allocator(self: *Site) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    pub fn deinit(self: *Site) void {
        self.source_root.close();
        self.web_paths.deinit(self.arena_state.child_allocator);
        self.arena_state.deinit();
    }

    pub fn addPage(self: *Site, page: Page) !PageIndex {
        const index = self.pages.count();
        const ptr = try self.pages.addOne(self.allocator());
        ptr.* = page;
        const get_or_put = try self.web_paths.getOrPut(
            // We shouldn't use the arena allocator for the hash map, so any
            // space it frees when it reshuffles data on insert is reclaimed.
            self.arena_state.child_allocator,
            page.web_path,
        );
        if (get_or_put.found_existing) {
            const existing_page = self.pages.at(@intFromEnum(get_or_put.value_ptr.*));
            try fail.prettily(
                \\I found multiple source files for a single page URL.
                \\
                \\These are the source files in question:
                \\
                \\  {s}
                \\  {s}
                \\
                \\The URL path I would use for both of these is:
                \\
                \\  {s}
                \\
                \\Tip: Rename one of the files so both get a unique URL.
                \\
            , .{ existing_page.source_path, page.source_path, page.web_path });
        } else {
            get_or_put.value_ptr.* = @enumFromInt(index);
        }
        return @enumFromInt(index);
    }

    pub const Rule = struct {
        patterns: []const []const u8,
        replaceTags: []const []const u8,
        processing: Processing,
    };

    pub const Page = struct {
        rule_index: usize,
        mime_type: mime.Type,
        output_len: ?u64,
        source_path: []const u8,
        output_path: []const u8,
        web_path: []const u8,
        frontmatter: []const u8,
    };

    pub const Processing = enum(u8) {
        bootstrap = 0,
        ignore = 1,
        markdown = 2,
        none = 3,
        xml = 4,
    };

    pub const PageIndex = enum(u32) { _ };
};
