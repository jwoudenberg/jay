// Contains the main data structure the host code is built around.

const builtin = @import("builtin");
const std = @import("std");
const fail = @import("fail.zig");
const mime = @import("mime");
const Frontmatters = @import("frontmatter.zig").Frontmatters;
const glob = @import("glob.zig");
const Str = @import("str.zig").Str;
const BitSet = @import("bitset.zig").BitSet;
const generate = @import("generate.zig").generate;

pub const Site = struct {
    // The allocator that should be used for content of this struct.
    arena_state: std.heap.ArenaAllocator,
    // An extra arena for short-lived jobs.
    tmp_arena_state: std.heap.ArenaAllocator,
    // Absolute path of the directory containing the static site project.
    source_root: std.fs.Dir,
    // basename of the .roc file we're currently running.
    roc_main: []const u8,
    // Str to the directory that will contain the generated site.
    output_root: std.fs.Dir,
    // Source patterns that should not be turned into pages.
    ignore_patterns: []Str,
    // The page-construction rules defined in the .roc file we're running.
    rules: []Rule,
    // The patterns we've seen passed to `list!` calls in the plastform.
    list_patterns: std.SegmentedList(ListPattern, 0),
    // For each page, which `list!`-patterns it maches.
    patterns_matched_by_page: std.SegmentedList(BitSet, 0),
    // A bitset containing the source pages we need to (re)scan outputs for.
    pages_to_scan: BitSet,
    // A bitset containing the source pages we need to (re)generate outputs for.
    pages_to_generate: BitSet,
    // Interned path slices
    strs: Str.Registry,
    // Stored frontmatters
    frontmatters: Frontmatters,

    // The pages in a project. This is a SegmentedList because it's an
    // arena-friendly datastructure and we don't require slicing pages. The
    // SegmentedList is put in a wrapper with a mutex for safer access, given
    // both the watch/build and serve threads read from it.
    pages: Pages,

    pub fn init(
        gpa: std.mem.Allocator,
        source_root: std.fs.Dir,
        roc_main: []const u8,
        output_path: []const u8,
        strs: Str.Registry,
    ) !Site {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        const arena = arena_state.allocator();
        const ignore_patterns = try arena.dupe(Str, &[implicit_ignore_pattern_count]Str{
            try strs.intern(output_path),
            try strs.intern(roc_main),
            try strs.intern(std.fs.path.stem(roc_main)),
        });

        source_root.deleteTree(output_path) catch |err| {
            if (err != error.NotDir) {
                return err;
            }
        };
        try source_root.makePath(output_path);
        const output_root = try source_root.openDir(output_path, .{});

        return Site{
            .arena_state = arena_state,
            .tmp_arena_state = std.heap.ArenaAllocator.init(gpa),
            .source_root = source_root,
            .roc_main = roc_main,
            .output_root = output_root,
            .ignore_patterns = ignore_patterns,
            .rules = &.{},
            .strs = strs,
            .list_patterns = std.SegmentedList(ListPattern, 0){},
            .patterns_matched_by_page = std.SegmentedList(BitSet, 0){},
            .pages_to_scan = BitSet{},
            .pages_to_generate = BitSet{},
            .frontmatters = Frontmatters.init(gpa),
            .pages = .{},
        };
    }

    const implicit_ignore_pattern_count = 3;

    pub fn user_ignore_patterns(self: *const Site) []Str {
        return self.ignore_patterns[implicit_ignore_pattern_count..];
    }

    pub fn deinit(self: *Site) void {
        self.frontmatters.deinit();
        self.arena_state.deinit();
        self.tmp_arena_state.deinit();
    }

    // TODO: would be nice to remove this, avoid external access to allocator.
    pub fn allocator(self: *Site) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    pub fn openSourceRoot(self: *const Site, args: std.fs.Dir.OpenDirOptions) !std.fs.Dir {
        return self.source_root.openDir(".", args);
    }

    pub fn getPage(self: *Site, path: Str) ?*Page {
        const page_index = path.index();
        if (page_index == Str.init_index) return null;
        const page = self.pages.at(page_index);
        page.mutex.lock();
        defer page.mutex.unlock();
        return if (page.deleted) null else page;
    }

    // Init a Page record for a source path if none exists yet and schedule it
    // for scanning.
    pub fn touchPage(self: *Site, source_path: Str) !void {
        if (source_path.index() != Str.init_index) return;

        const page_index: usize = self.pages.count();
        _ = source_path.replaceIndex(page_index);
        try self.pages_to_scan.setValue(self.allocator(), page_index, true);

        // Find matching rule.
        const rule_index = try self.ruleForPath(source_path);
        const rule = self.rules[rule_index];

        // Calculate output path.
        const output_path = switch (rule.processing) {
            .xml, .none => source_path,
            .markdown => blk: {
                var buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
                const output_path_bytes = try outputPathForMarkdownFile(&buffer, source_path.bytes());
                break :blk try self.strs.intern(output_path_bytes);
            },
        };
        _ = output_path.replaceIndex(page_index);

        // Calculate web path.
        const extension = std.fs.path.extension(output_path.bytes());
        const mime_type = mime.extension_map.get(extension) orelse .@"application/octet-stream";
        const web_path = try self.strs.intern(webPathFromFilePath(output_path.bytes()));
        const old_web_path_index = web_path.replaceIndex(page_index);
        if (old_web_path_index != Str.init_index and old_web_path_index != page_index) {
            const existing = self.pages.at(old_web_path_index);
            existing.mutex.lock();
            defer existing.mutex.unlock();
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
            , .{ existing.source_path.bytes(), source_path.bytes(), web_path.bytes() });
        }

        // Create page.
        const page = Site.Page{
            .mutex = std.Thread.Mutex{},
            .source_path = source_path,
            .rule_index = rule_index,
            .processing = rule.processing,
            .replace_tags = rule.replace_tags,
            .mime_type = mime_type,
            .output_path = output_path,
            .web_path = web_path,

            // Set when we first scan the page.
            .output_len = null,
            .deleted = undefined,
            .last_modified = undefined,
            .frontmatter = undefined,
        };
        try self.pages.append(self.allocator(), page);

        // Update pattern-match cache.
        var patterns_matched = try self.ensurePatternsMatchedForPage(source_path);
        var list_patterns = self.list_patterns.constIterator(0);
        while (list_patterns.next()) |list_pattern| {
            const pattern = list_pattern.pattern;
            if (glob.match(pattern.bytes(), source_path.bytes())) {
                try patterns_matched.setValue(self.allocator(), pattern.index(), true);
            }
        }
    }

    test touchPage {
        var test_site = try TestSite.init();
        defer test_site.deinit();
        var site = test_site.site;
        var rules = [_]Site.Rule{
            Site.Rule{
                .processing = .markdown,
                .patterns = try test_site.strsFromSlices(&.{"*.md"}),
                .replace_tags = try test_site.strsFromSlices(&.{ "tag1", "tag2" }),
            },
            Site.Rule{
                .processing = .none,
                .patterns = try test_site.strsFromSlices(&.{"*.css"}),
                .replace_tags = try test_site.strsFromSlices(&.{"tag3"}),
            },
        };
        site.rules = &rules;

        try site.source_root.writeFile(.{ .sub_path = "file.md", .data = "{}\x02" });
        try site.source_root.writeFile(.{ .sub_path = "style.css", .data = "" });

        // Insert markdown file.
        const file_md = try site.strs.intern("file.md");
        try site.touchPage(file_md);
        const md_page = site.getPage(file_md).?;
        try std.testing.expectEqual(0, md_page.rule_index);
        try std.testing.expectEqualStrings("file.md", md_page.source_path.bytes());
        try std.testing.expectEqualStrings("file.html", md_page.output_path.bytes());
        try std.testing.expectEqualStrings("file", md_page.web_path.bytes());
        try std.testing.expectEqual(0, md_page.source_path.index());
        try std.testing.expectEqual(0, md_page.web_path.index());
        try std.testing.expectEqual(0, md_page.output_path.index());
        try std.testing.expectEqual(.markdown, md_page.processing);
        try std.testing.expectEqual(site.rules[0].replace_tags, md_page.replace_tags);
        try std.testing.expectEqual(null, md_page.output_len);

        // Insert static file.
        const style_css = try site.strs.intern("style.css");
        try site.touchPage(style_css);
        const css_page = site.getPage(style_css).?;
        try std.testing.expectEqual(1, css_page.rule_index);
        try std.testing.expectEqualStrings("style.css", css_page.source_path.bytes());
        try std.testing.expectEqualStrings("style.css", css_page.output_path.bytes());
        try std.testing.expectEqualStrings("style.css", css_page.web_path.bytes());
        try std.testing.expectEqual(1, css_page.source_path.index());
        try std.testing.expectEqual(1, css_page.web_path.index());
        try std.testing.expectEqual(1, css_page.output_path.index());
        try std.testing.expectEqual(.none, css_page.processing);
        try std.testing.expectEqual(site.rules[1].replace_tags, css_page.replace_tags);
        try std.testing.expectEqual(null, css_page.output_len);
    }

    // Perform page scans and generations in a loop, until none are left to-do.
    // We first scan all pages in the queue, then generate output for all those
    // pages. The reason is that page generation might use `list!` to get
    // metadata on other pages that requires scanning them first.
    //
    // The separate scan and generate phases have the downside that we read the
    // file twice, once during scanning to get the frontmatter, then again
    // during generation to read the full file. The source file might have
    // changed in the meanwhile, resulting in bad content being generated.
    // We're currently relying on the bad generated content only existing
    // briefly because the change to source content will have queued another
    // scan.
    //
    // TODO: Prevent bad generated content by writing output content to a
    // temporary file, checking after if the source file modified timestamp
    // hasn't changed, and only then moving the generated output to the output
    // directory.
    pub fn scanAndGeneratePages(self: *Site) !void {
        while (true) {
            _ = self.tmp_arena_state.reset(.{ .retain_with_limit = 1024 * 1024 });
            if (self.pages_to_scan.findFirstSet()) |page_index| {
                const page = self.pages.at(page_index);
                page.mutex.lock();
                defer page.mutex.unlock();
                try self.pages_to_scan.setValue(self.allocator(), page_index, false);
                try self.scanPage(page);
                continue;
            }
            if (self.pages_to_generate.findFirstSet()) |page_index| {
                const page = self.pages.at(page_index);
                page.mutex.lock();
                defer page.mutex.unlock();
                try self.pages_to_generate.setValue(self.allocator(), page_index, false);
                try generate(self.tmp_arena_state.allocator(), self, page);
                continue;
            }
            return;
        }
    }

    fn scanPage(self: *Site, page: *Page) !void {
        // Check file modification time and existence.
        const stat = self.source_root.statFile(page.source_path.bytes()) catch |err| {
            if (err == error.FileNotFound) {
                page.deleted = true;
                // Clear the page index on output and web strs, so that other pages
                // might reuse these without reporting a conflict.
                _ = page.output_path.replaceIndex(Str.init_index);
                _ = page.web_path.replaceIndex(Str.init_index);
                return;
            } else return err;
        };

        if (page.deleted) {
            try scheduleGenerateForPageAndDepdendents(self, page);
            page.deleted = false;
        } else if (page.last_modified == stat.mtime) {
            return;
        }
        page.last_modified = stat.mtime;

        const old_frontmatter = page.frontmatter;
        const arena = self.tmp_arena_state.allocator();
        page.frontmatter = try self.frontmatters.read(arena, self.source_root, page.source_path);
        if (old_frontmatter.ptr != page.frontmatter.ptr) {
            try scheduleGenerateForPageAndDepdendents(self, page);
        }
    }

    test scanPage {
        var test_site = try TestSite.init();
        defer test_site.deinit();
        var site = test_site.site;
        var rules = [_]Site.Rule{
            Site.Rule{
                .processing = .markdown,
                .patterns = try test_site.strsFromSlices(&.{"*.md"}),
                .replace_tags = try test_site.strsFromSlices(&.{ "tag1", "tag2" }),
            },
            Site.Rule{
                .processing = .none,
                .patterns = try test_site.strsFromSlices(&.{"*.css"}),
                .replace_tags = try test_site.strsFromSlices(&.{"tag3"}),
            },
        };
        site.rules = &rules;

        // Insert markdown file.
        try site.source_root.writeFile(.{ .sub_path = "file.md", .data = "{}\x02" });
        const file_md = try site.strs.intern("file.md");
        try site.touchPage(file_md);
        const md_page = site.getPage(file_md).?;
        try site.scanPage(md_page);
        try std.testing.expect(site.pages_to_generate.isSet(md_page.source_path.index()));
        try std.testing.expect(!md_page.deleted);
        try std.testing.expectEqual(null, md_page.output_len);
        try std.testing.expectEqualStrings("{}", md_page.frontmatter);
        try std.testing.expectEqualStrings("text/html", @tagName(md_page.mime_type));

        // Insert static file.
        try site.source_root.writeFile(.{ .sub_path = "style.css", .data = "" });
        const style_css = try site.strs.intern("style.css");
        try site.touchPage(style_css);
        const css_page = site.getPage(style_css).?;
        try site.scanPage(css_page);
        try std.testing.expect(site.pages_to_generate.isSet(css_page.source_path.index()));
        try std.testing.expect(!css_page.deleted);
        try std.testing.expectEqual(null, css_page.output_len);
        try std.testing.expectEqualStrings("{}", css_page.frontmatter);
        try std.testing.expectEqualStrings("text/css", @tagName(css_page.mime_type));

        // Update markdown file without making changes.
        site.pages_to_generate.unsetAll(); // clear flags
        try site.scanPage(md_page);
        try std.testing.expect(!site.pages_to_generate.isSet(md_page.source_path.index()));
        try std.testing.expect(!md_page.deleted);

        // Update markdown file making changes.
        site.pages_to_generate.unsetAll(); // clear flags
        try site.source_root.writeFile(.{ .sub_path = "file.md", .data = "{ hi: 4 }\x09" });
        try site.scanPage(md_page);
        try std.testing.expect(site.pages_to_generate.isSet(md_page.source_path.index()));
        try std.testing.expect(!md_page.deleted);
        try std.testing.expectEqualStrings("{ hi: 4 }", md_page.frontmatter);

        // Delete markdown file
        site.pages_to_generate.unsetAll(); // clear flags
        try site.source_root.deleteFile("file.md");
        try site.scanPage(md_page);
        try std.testing.expect(!site.pages_to_generate.isSet(md_page.source_path.index()));
        try std.testing.expect(md_page.deleted);
        try std.testing.expectEqual(null, site.getPage(file_md));
        try std.testing.expectEqual(Str.init_index, (try site.strs.intern("file.html")).index());
        try std.testing.expectEqual(Str.init_index, (try site.strs.intern("file")).index());

        // Recreate a markdown file
        site.pages_to_generate.unsetAll(); // clear flags
        try site.source_root.writeFile(.{ .sub_path = "file.md", .data = "{}\x02" });
        try site.scanPage(md_page);
        try std.testing.expect(site.pages_to_generate.isSet(md_page.source_path.index()));
        try std.testing.expect(!md_page.deleted);
        try std.testing.expectEqual(null, md_page.output_len);
        try std.testing.expectEqualStrings("{}", md_page.frontmatter);
        try std.testing.expectEqualStrings("text/html", @tagName(md_page.mime_type));
    }

    fn scheduleGenerateForPageAndDepdendents(self: *Site, page: *Page) !void {
        const arena = self.allocator();
        const self_page_index = page.source_path.index();
        try self.pages_to_generate.setValue(arena, self_page_index, true);

        var pattern_indexes = self.patterns_matched_by_page.at(self_page_index).iterator();
        while (pattern_indexes.next()) |pattern_index| {
            var page_uses = self.list_patterns.at(pattern_index).page_uses.iterator();
            while (page_uses.next()) |page_index| {
                try self.pages_to_generate.setValue(arena, page_index, true);
            }
        }
    }

    pub const Rule = struct {
        patterns: []Str,
        replace_tags: []Str,
        processing: Processing,
    };

    pub const ListPattern = struct {
        pattern: Str,
        page_uses: BitSet,
    };

    pub const Page = struct {
        mutex: std.Thread.Mutex,
        source_path: Str,

        // Rule-derived attributes
        rule_index: usize,
        replace_tags: []Str,
        processing: Processing,
        mime_type: mime.Type,
        output_path: Str,
        web_path: Str,

        // Filesystem-derived attributes
        output_len: ?u64,
        frontmatter: []const u8,
        last_modified: i128,
        deleted: bool,
    };

    // Enum pairs should be a subset of those in Platform.Processing enum.
    pub const Processing = enum(u8) {
        markdown = 2,
        none = 3,
        xml = 4,
    };

    pub fn pagesMatchingPattern(
        self: *Site,
        requester: Str,
        pattern_bytes: []const u8,
    ) !PatternIterator {
        // Ensure list pattern is stored.
        const pattern = try self.strs.intern(pattern_bytes);
        if (pattern.index() == Str.init_index) {
            const pattern_index = self.list_patterns.count();
            _ = pattern.replaceIndex(pattern_index);
            var list_pattern = .{
                .pattern = pattern,
                .page_uses = BitSet{},
            };
            try self.list_patterns.append(self.allocator(), list_pattern);
            try self.backfillPagesMatched(&list_pattern);
        }

        // Ensure page is marked as a user of the pattern, for tracking
        // dependencies. Note that we do not remove a dependency on a pattern
        // after it is added, unless all patterns are invalidated as part of
        // rules changing. That might result in the occasional unnecessary
        // regenerated output file, but it should be pretty rare.
        const list_pattern = self.list_patterns.at(pattern.index());
        const page_index = requester.index();
        try list_pattern.page_uses.setValue(self.allocator(), page_index, true);

        return PatternIterator{
            .site = self,
            .pattern = pattern,
            .next_page_index = 0,
        };
    }

    fn backfillPagesMatched(self: *Site, list_pattern: *ListPattern) !void {
        var pages = self.pages.iterator(0);
        const pattern_bytes = list_pattern.pattern.bytes();
        while (pages.next()) |page| {
            var patterns_matched = try self.ensurePatternsMatchedForPage(page.source_path);
            if (glob.match(pattern_bytes, page.source_path.bytes())) {
                try patterns_matched.setValue(self.allocator(), list_pattern.pattern.index(), true);
            }
        }
    }

    fn ensurePatternsMatchedForPage(self: *Site, source_path: Str) !*BitSet {
        const page_index = source_path.index();
        while (page_index >= self.patterns_matched_by_page.count()) {
            const arena = self.allocator();
            const patterns_matched = BitSet{};
            try self.patterns_matched_by_page.append(arena, patterns_matched);
        }
        return self.patterns_matched_by_page.at(page_index);
    }

    pub const PatternIterator = struct {
        site: *Site,
        pattern: Str,
        next_page_index: usize,

        pub fn next(self: *PatternIterator) ?*Page {
            const pattern_index = self.pattern.index();
            while (self.next_page_index < self.site.pages.count()) {
                const page_index = self.next_page_index;
                self.next_page_index += 1;
                const matches = self.site.patterns_matched_by_page.at(page_index);
                if (matches.isSet(pattern_index)) return self.site.pages.at(page_index);
            }
            return null;
        }
    };

    fn ruleForPath(site: *Site, source_path: Str) !usize {
        var matches: [10]usize = undefined;
        var len: u8 = 0;

        for (site.rules, 0..) |rule, rule_index| {
            if (!matchAny(rule.patterns, source_path.bytes())) continue;

            matches[len] = rule_index;
            len += 1;
            if (len > matches.len) break;
        }

        return switch (len) {
            1 => matches[0],
            0 => try fail.prettily(
                \\I can't find a pattern matching the following source path:
                \\
                \\    {s}
                \\
                \\Make sure each path in your project directory is matched by
                \\a rule, or an ignore pattern.
                \\
                \\Tip: Add an extra rule like this:
                \\
                \\    Pages.files ["{s}"]
                \\
                \\
            , .{ source_path.bytes(), source_path.bytes() }),
            else => try fail.prettily(
                \\The following file is matched by multiple rules:
                \\
                \\    {s}
                \\
                \\These are the indices of the rules that match:
                \\
                \\    {any}
                \\
                \\
            , .{ source_path.bytes(), matches }),
        };
    }

    test ruleForPath {
        var test_site = try TestSite.init();
        defer test_site.deinit();
        var site = test_site.site;
        var rules = [_]Site.Rule{
            Site.Rule{
                .processing = .markdown,
                .patterns = try test_site.strsFromSlices(&.{ "rule_one/*", "conflicting/*" }),
                .replace_tags = &.{},
            },
            Site.Rule{
                .processing = .none,
                .patterns = try test_site.strsFromSlices(&.{ "rule_two/*", "conflicting/*" }),
                .replace_tags = &.{},
            },
        };
        site.rules = &rules;

        try std.testing.expectEqual(
            0,
            site.ruleForPath(try site.strs.intern("rule_one/file.txt")),
        );
        try std.testing.expectEqual(
            1,
            site.ruleForPath(try site.strs.intern("rule_two/file.txt")),
        );
        try std.testing.expectEqual(
            error.PrettyError,
            site.ruleForPath(try site.strs.intern("shared/file.txt")),
        );
        try std.testing.expectEqual(
            error.PrettyError,
            site.ruleForPath(try site.strs.intern("missing/file.txt")),
        );
    }

    pub fn isMarkdown(path: []const u8) bool {
        const extension = std.fs.path.extension(path);
        return std.ascii.eqlIgnoreCase(extension, ".md") or
            std.ascii.eqlIgnoreCase(extension, ".markdown");
    }

    test isMarkdown {
        try std.testing.expect(isMarkdown("file.md"));
        try std.testing.expect(isMarkdown("dir/file.MD"));
        try std.testing.expect(isMarkdown("file.MarkDown"));
        try std.testing.expect(!isMarkdown("file.txt"));
    }

    fn outputPathForMarkdownFile(buffer: []u8, path: []const u8) ![]const u8 {
        if (!isMarkdown(path)) {
            try fail.prettily("You're asking me to process a file as markdown, but it does not have a markdown file extension: {s}", .{path});
        }
        return std.fmt.bufPrint(
            buffer,
            "{s}.html",
            .{path[0..(path.len - std.fs.path.extension(path).len)]},
        );
    }

    test outputPathForMarkdownFile {
        var buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const actual = try outputPathForMarkdownFile(&buffer, "file.md");
        try std.testing.expectEqualStrings("file.html", actual);

        try std.testing.expectError(
            error.PrettyError,
            outputPathForMarkdownFile(&buffer, "file.txt"),
        );
    }

    pub fn matchAny(patterns: []Str, path: []const u8) bool {
        for (patterns) |pattern| {
            if (glob.match(pattern.bytes(), path)) return true;
        } else {
            return false;
        }
    }

    // SegmentedList wrapped together with a Mutex to allow threadsafe access.
    // There's plans to make this unnecessary:
    // https://github.com/ziglang/zig/issues/20491
    const Pages = struct {
        internal: std.SegmentedList(Page, 0) = .{},
        mutex: std.Thread.Mutex = .{},

        fn deinit(self: *Pages) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.internal.deinit();
        }

        fn at(self: *Pages, index: usize) *Page {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.internal.at(index);
        }

        fn append(self: *Pages, alloc: std.mem.Allocator, item: Page) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.internal.append(alloc, item);
        }

        fn count(self: *Pages) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.internal.count();
        }

        fn iterator(self: *Pages, start: usize) Iterator {
            return .{
                .pages = self,
                .next_index = start,
            };
        }

        const Iterator = struct {
            pages: *Pages,
            next_index: usize,

            pub fn next(self: *Iterator) ?*Page {
                if (self.next_index >= self.pages.count()) return null;
                const page = self.pages.at(self.next_index);
                self.next_index += 1;
                return page;
            }
        };
    };
};

pub const TestSite = struct {
    site: *Site,
    strs: Str.Registry,
    root: std.testing.TmpDir,

    pub fn init() !TestSite {
        if (!builtin.is_test) @panic("TestSite.init is intended for tests only");
        const tmpdir = std.testing.tmpDir(.{});
        const strs = try Str.Registry.init(std.testing.allocator);
        const site = try std.testing.allocator.create(Site);
        site.* = try Site.init(std.testing.allocator, tmpdir.dir, "build.roc", "output", strs);
        return TestSite{
            .site = site,
            .strs = strs,
            .root = tmpdir,
        };
    }

    pub fn deinit(self: *TestSite) void {
        self.site.deinit();
        self.strs.deinit();
        self.root.cleanup();
        std.testing.allocator.destroy(self.site);
    }

    pub fn strsFromSlices(self: *TestSite, slices: []const []const u8) ![]Str {
        if (!builtin.is_test) @panic("strsFromSlices is intended for tests only");
        var strs = try self.site.allocator().alloc(Str, slices.len);
        for (slices, 0..) |slice, index| {
            strs[index] = try self.strs.intern(slice);
        }
        return strs;
    }
};

fn webPathFromFilePath(path: []const u8) []const u8 {
    if (std.mem.eql(u8, "index.html", std.fs.path.basename(path))) {
        return std.fs.path.dirname(path) orelse "";
    } else if (std.mem.eql(u8, ".html", std.fs.path.extension(path))) {
        return path[0..(path.len - ".html".len)];
    } else {
        return path;
    }
}

test webPathFromFilePath {
    try std.testing.expectEqualStrings("hi/file.css", webPathFromFilePath("hi/file.css"));
    try std.testing.expectEqualStrings("hi/file", webPathFromFilePath("hi/file.html"));
    try std.testing.expectEqualStrings("hi", webPathFromFilePath("hi/index.html"));
}
