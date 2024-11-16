// Contains the main data structure the host code is built around.

const std = @import("std");
const fail = @import("fail.zig");
const mime = @import("mime");
const glob = @import("glob.zig");

pub const Site = struct {
    // The allocator that should be used for content of the struct.
    arena_state: std.heap.ArenaAllocator,
    // Absolute path of the directory containing the static site project.
    source_root: []const u8,
    // basename of the .roc file we're currently running.
    roc_main: []const u8,
    // Path to the directory that will contain the generated site.
    output_root: []const u8,
    // Source patterns that should be turned into pages.
    ignore_patterns: []const []const u8,
    // The page-construction rules defined in the .roc file we're running.
    rules: []Rule,

    // The pages in a project. Append only so multiple threads can safely read
    // from this data. Writers need to obtain a lock first.
    pages: std.SegmentedList(Page, 0),
    web_paths: std.StringHashMapUnmanaged(PageIndex),
    source_paths: std.StringHashMapUnmanaged(PageIndex),

    path_mutex: std.Thread.Mutex,

    pub fn init(
        base_allocator: std.mem.Allocator,
        argv0: []const u8,
        output_root: []const u8,
    ) !Site {
        var arena_state = std.heap.ArenaAllocator.init(base_allocator);
        const arena = arena_state.allocator();
        const argv0_abs = try std.fs.cwd().realpathAlloc(arena, argv0);
        const source_root = std.fs.path.dirname(argv0_abs) orelse "/";
        const roc_main = std.fs.path.basename(argv0_abs);
        const ignore_patterns = try arena.dupe([]const u8, &[implicit_ignore_pattern_count][]const u8{
            output_root,
            roc_main,
            std.fs.path.stem(roc_main),
        });

        return Site{
            .arena_state = arena_state,
            .source_root = source_root,
            .roc_main = roc_main,
            .output_root = output_root,
            .ignore_patterns = ignore_patterns,
            .rules = &.{},
            .path_mutex = std.Thread.Mutex{},

            // Pages
            .pages = std.SegmentedList(Page, 0){},
            .web_paths = std.StringHashMapUnmanaged(PageIndex){},
            .source_paths = std.StringHashMapUnmanaged(PageIndex){},
        };
    }

    const implicit_ignore_pattern_count = 3;

    pub fn user_ignore_patterns(self: *const Site) []const []const u8 {
        return self.ignore_patterns[implicit_ignore_pattern_count..];
    }

    pub fn allocator(self: *Site) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    pub fn deinit(self: *Site) void {
        self.web_paths.deinit(self.arena_state.child_allocator);
        self.source_paths.deinit(self.arena_state.child_allocator);
        self.arena_state.deinit();
    }

    pub fn openSourceRoot(self: *const Site, args: std.fs.Dir.OpenDirOptions) !std.fs.Dir {
        return std.fs.cwd().openDir(self.source_root, args) catch |err| {
            try fail.prettily(
                "Cannot access directory containing {s}: '{}'\n",
                .{ self.source_root, err },
            );
        };
    }

    pub fn getPage(self: *Site, index: PageIndex) *Page {
        self.path_mutex.lock();
        defer self.path_mutex.unlock();

        return self.pages.at(@intFromEnum(index));
    }

    pub fn pageIndex(self: *Site, source_path: []const u8) !?PageIndex {
        if (glob.matchAny(self.ignore_patterns, source_path)) return null;

        self.path_mutex.lock();
        defer self.path_mutex.unlock();

        const get_or_put = try self.source_paths.getOrPut(
            // We shouldn't use the arena allocator for the hash map, so any
            // space it frees when it reshuffles data on insert is reclaimed.
            self.arena_state.child_allocator,
            source_path,
        );
        if (get_or_put.found_existing) {
            return get_or_put.value_ptr.*;
        } else {
            const new_index: PageIndex = @enumFromInt(self.pages.count());
            _ = try self.pages.addOne(self.allocator());
            get_or_put.value_ptr.* = new_index;
            return new_index;
        }
    }

    pub fn addPage(self: *Site, page: Page) !PageIndex {
        const index = (try self.pageIndex(page.source_path)) orelse {
            return error.CantCreatePageForIgnoredPath;
        };

        self.path_mutex.lock();
        defer self.path_mutex.unlock();

        self.pages.at(@intFromEnum(index)).* = page;
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
            get_or_put.value_ptr.* = index;
        }
        return index;
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

    // Enum pairs should be a subset of those in Platform.Processing enum.
    pub const Processing = enum(u8) {
        markdown = 2,
        none = 3,
        xml = 4,
    };

    pub const PageIndex = enum(u32) { _ };
};
