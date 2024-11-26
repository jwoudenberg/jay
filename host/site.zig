// Contains the main data structure the host code is built around.

const std = @import("std");
const fail = @import("fail.zig");
const mime = @import("mime");
const glob = @import("glob.zig");
const Path = @import("path.zig").Path;
const native_endian = @import("builtin").target.cpu.arch.endian();

pub const Site = struct {
    // The allocator that should be used for content of the struct.
    arena_state: std.heap.ArenaAllocator,
    // Absolute path of the directory containing the static site project.
    source_root: []const u8,
    // basename of the .roc file we're currently running.
    roc_main: []const u8,
    // Path to the directory that will contain the generated site.
    output_root: []const u8,
    // Source patterns that should not be turned into pages.
    ignore_patterns: []const []const u8,
    // The page-construction rules defined in the .roc file we're running.
    rules: []Rule,

    // The pages in a project. Using arena-friendly datastructures that don't
    // reallocate when new pages are added.
    pages: std.SegmentedList(Page, 0),
    pages_by_index: std.SegmentedList(?*Page, 0),
    mutex: std.Thread.Mutex,

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
            .pages = std.SegmentedList(Page, 0){},
            .pages_by_index = std.SegmentedList(?*Page, 0){},
            .mutex = std.Thread.Mutex{},
        };
    }

    const implicit_ignore_pattern_count = 3;

    pub fn user_ignore_patterns(self: *const Site) []const []const u8 {
        return self.ignore_patterns[implicit_ignore_pattern_count..];
    }

    pub fn deinit(self: *Site) void {
        self.arena_state.deinit();
    }

    // TODO: would be nice to remove this, avoid external access to allocator.
    pub fn allocator(self: *Site) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    pub fn openSourceRoot(self: *const Site, args: std.fs.Dir.OpenDirOptions) !std.fs.Dir {
        return std.fs.cwd().openDir(self.source_root, args) catch |err| {
            try fail.prettily(
                "Cannot access directory containing {s}: '{}'\n",
                .{ self.source_root, err },
            );
        };
    }

    pub fn getPage(self: *Site, path: Path) ?*Page {
        self.mutex.lock();
        defer self.mutex.unlock();
        const index = path.index();
        if (index >= self.pages_by_index.count()) return null;
        return self.pages_by_index.at(index).*;
    }

    pub fn addPage(self: *Site, stack_page: Page) !*Page {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Copy the page into owned memory.
        var page = try self.pages.addOne(self.allocator());
        page.* = stack_page;

        const page_ptr = try self.pagePtrForIndex(page.source_path.index());
        std.debug.assert(page_ptr.* == null);
        page_ptr.* = page;

        if (page.source_path != page.output_path) {
            const output_ptr = try self.pagePtrForIndex(page.output_path.index());
            std.debug.assert(output_ptr.* == null);
            output_ptr.* = page;
        }

        if (page.source_path != page.web_path) {
            const web_ptr = try self.pagePtrForIndex(page.web_path.index());
            if (web_ptr.*) |existing| {
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
                , .{ existing.source_path.bytes(), page.source_path.bytes(), page.web_path.bytes() });
            }
            web_ptr.* = page;
        }

        return page;
    }

    fn pagePtrForIndex(self: *Site, index: usize) !*?*Page {
        const arena = self.allocator();
        while (index >= self.pages_by_index.count()) {
            _ = try self.pages_by_index.append(arena, null);
        }
        return self.pages_by_index.at(index);
    }

    pub fn iterator(self: *Site) Iterator {
        return Iterator{
            .site = self,
            .next_index = 0,
        };
    }

    pub const Rule = struct {
        patterns: []const []const u8,
        replace_tags: []const []const u8,
        processing: Processing,
    };

    pub const Page = struct {
        mutex: std.Thread.Mutex,
        rule_index: usize,
        replace_tags: []const []const u8,
        processing: Processing,
        mime_type: mime.Type,
        output_len: ?u64,
        source_path: Path,
        output_path: Path,
        web_path: Path,
        frontmatter: []const u8,
    };

    // Enum pairs should be a subset of those in Platform.Processing enum.
    pub const Processing = enum(u8) {
        markdown = 2,
        none = 3,
        xml = 4,
    };

    pub const Iterator = struct {
        site: *Site,
        next_index: usize,

        pub fn next(self: *Iterator) ?*Page {
            self.site.mutex.lock();
            defer self.site.mutex.unlock();
            if (self.next_index >= self.site.pages.count()) return null;
            const page = self.site.pages.at(self.next_index);
            self.next_index += 1;
            return page;
        }
    };
};
