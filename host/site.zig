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
const Error = @import("error.zig").Error;
const Platform = @import("platform.zig").Platform;
const RocPlatform = @import("platform.zig").RocPlatform;
const TestPlatform = @import("platform.zig").TestPlatform;
const BootstrapPlatform = @import("platform.zig").BootstrapPlatform;
const bootstrap = @import("bootstrap.zig").bootstrap;

pub const Site = struct {
    arena_state: std.heap.ArenaAllocator,
    tmp_arena_state: std.heap.ArenaAllocator,
    platform: *Platform,
    source_root: std.fs.Dir,
    roc_main: Str,
    output_root: std.fs.Dir,
    ignore_patterns: []Str,
    rules: []Rule,
    list_patterns: std.SegmentedList(ListPattern, 0),
    patterns_matched_by_page: std.SegmentedList(BitSet, 0),
    pages_to_generate: BitSet,
    strs: Str.Registry,
    frontmatters: Frontmatters,
    errors: Error.Index,

    // The pages in a project. This is a SegmentedList because it's an
    // arena-friendly datastructure and we don't require slicing pages. The
    // SegmentedList is put in a wrapper with a mutex for safer access, given
    // both the watch/build and serve threads read from it.
    pages: Pages,

    pub fn init(
        gpa: std.mem.Allocator,
        source_root: std.fs.Dir,
        roc_main: []const u8,
        output_root: std.fs.Dir,
        strs: Str.Registry,
    ) !Site {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        const arena = arena_state.allocator();
        const roc_main_str = try strs.intern(roc_main);

        const ignore_patterns = try arena.dupe(Str, &[implicit_ignore_pattern_count]Str{
            roc_main_str,
            try strs.intern(std.fs.path.stem(roc_main)),
        });

        const platform = if (builtin.is_test)
            try TestPlatform.init()
        else
            try RocPlatform.init(gpa);

        var site = Site{
            .arena_state = arena_state,
            .tmp_arena_state = std.heap.ArenaAllocator.init(gpa),
            .source_root = source_root,
            .platform = platform,
            .roc_main = roc_main_str,
            .output_root = output_root,
            .ignore_patterns = ignore_patterns,
            .rules = &.{},
            .strs = strs,
            .list_patterns = std.SegmentedList(ListPattern, 0){},
            .patterns_matched_by_page = std.SegmentedList(BitSet, 0){},
            .pages_to_generate = BitSet{},
            .frontmatters = Frontmatters.init(gpa),
            .errors = Error.Index.init(gpa),
            .pages = .{},
        };

        const should_bootstrap = try platform.getRules(gpa, &site);

        if (should_bootstrap) {
            try bootstrap(gpa, &site);
            site.platform.deinit();
            site.platform = if (builtin.is_test)
                try TestPlatform.init()
            else
                try BootstrapPlatform.init(gpa);
        }

        return site;
    }

    const implicit_ignore_pattern_count = 2;

    pub fn user_ignore_patterns(self: *const Site) []Str {
        return self.ignore_patterns[implicit_ignore_pattern_count..];
    }

    pub fn deinit(self: *Site) void {
        self.frontmatters.deinit();
        self.platform.deinit();
        self.errors.deinit();
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
        return if (page.scanned == null) null else page;
    }

    // Notify Site of the existence or changes to a source path.
    pub fn touchPath(self: *Site, source_path: Str, is_dir: bool) !void {
        // If a path changed its sub paths might be affected to. Scan those
        // first. This can be relevant if we swap out a directory path with a
        // file.
        var pages = self.iterator();
        while (pages.next()) |page| {
            // TODO: consider optimizing away the string comparisons.
            if (page.source_path != source_path and
                std.mem.startsWith(u8, page.source_path.bytes(), source_path.bytes()))
            {
                try self.touchPage(page.source_path, false);
            }
        }
        try self.touchPage(source_path, is_dir);
    }

    pub fn touchPage(self: *Site, source_path: Str, is_dir: bool) !void {
        _ = self.tmp_arena_state.reset(.{ .retain_with_limit = 1024 * 1024 });
        const is_new =
            source_path.index() == Str.init_index or
            source_path != self.pages.at(source_path.index()).source_path;

        // Not using Zig's std.fs.Dir.statFile here because it follows
        // symlinks. If the path is a symlinked file we want to detect it so
        // we can show an error.
        file_exists: {
            const posix_stat = std.posix.fstatat(
                self.source_root.fd,
                source_path.bytes(),
                std.posix.AT.SYMLINK_NOFOLLOW,
            ) catch |err| switch (err) {
                error.FileNotFound => break :file_exists,
                error.AccessDenied => return self.errors.add(
                    source_path,
                    Error{ .source_path_access_denied = source_path },
                ),
                error.InvalidUtf8,
                error.NameTooLong,
                error.SymLinkLoop,
                error.SystemResources,
                error.Unexpected,
                => return err,
            };
            const stat = std.fs.File.Stat.fromSystem(posix_stat);
            if (is_dir) break :file_exists;
            return if (is_new)
                self.initPage(source_path, stat)
            else
                self.scanPage(source_path, stat);
        }

        // File was deleted
        if (is_new) {
            self.errors.remove(source_path);
        } else {
            try self.deletePage(source_path);
        }
    }

    test touchPath {
        var test_site = try TestSite.init(.{
            .markdown_patterns = &.{"*.md"},
            .static_patterns = &.{"*.css"},
        });
        defer test_site.deinit();
        var site = test_site.site;

        try site.source_root.writeFile(.{ .sub_path = "file.md", .data = "{}\x02" });
        try site.source_root.writeFile(.{ .sub_path = "style.css", .data = "" });

        // Insert markdown file.
        const file_md = try site.strs.intern("file.md");
        try site.touchPath(file_md, false);
        const md_page = site.getPage(file_md).?;
        try std.testing.expectEqual(0, md_page.rule_index);
        try std.testing.expectEqualStrings("file.md", md_page.source_path.bytes());
        try std.testing.expectEqualStrings("file.html", md_page.scanned.?.output_path.bytes());
        try std.testing.expectEqualStrings("file", md_page.scanned.?.web_path.bytes());
        try std.testing.expectEqual(0, md_page.source_path.index());
        try std.testing.expectEqual(0, md_page.scanned.?.web_path.index());
        try std.testing.expectEqual(0, md_page.scanned.?.output_path.index());
        try std.testing.expectEqual(.markdown, md_page.processing);
        try std.testing.expectEqual(site.rules[0].replace_tags, md_page.replace_tags);
        try std.testing.expectEqual(null, md_page.generated);
        try std.testing.expect(site.pages_to_generate.isSet(md_page.source_path.index()));
        try std.testing.expectEqualStrings("{}", md_page.scanned.?.frontmatter.?);
        try std.testing.expectEqualStrings("text/html", @tagName(md_page.scanned.?.mime_type));

        // Insert static file.
        const style_css = try site.strs.intern("style.css");
        try site.touchPath(style_css, false);
        const css_page = site.getPage(style_css).?;
        try std.testing.expectEqual(1, css_page.rule_index);
        try std.testing.expectEqualStrings("style.css", css_page.source_path.bytes());
        try std.testing.expectEqualStrings("style.css", css_page.scanned.?.output_path.bytes());
        try std.testing.expectEqualStrings("style.css", css_page.scanned.?.web_path.bytes());
        try std.testing.expectEqual(1, css_page.source_path.index());
        try std.testing.expectEqual(1, css_page.scanned.?.web_path.index());
        try std.testing.expectEqual(1, css_page.scanned.?.output_path.index());
        try std.testing.expectEqual(.none, css_page.processing);
        try std.testing.expectEqual(site.rules[1].replace_tags, css_page.replace_tags);
        try std.testing.expectEqual(null, css_page.generated);
        try std.testing.expect(site.pages_to_generate.isSet(css_page.source_path.index()));
        try std.testing.expectEqualStrings("{}", css_page.scanned.?.frontmatter.?);
        try std.testing.expectEqualStrings("text/css", @tagName(css_page.scanned.?.mime_type));

        // Update markdown file making changes.
        site.pages_to_generate.unsetAll(); // clear flags
        try site.source_root.writeFile(.{ .sub_path = "file.md", .data = "{ hi: 4 }\x09" });
        try site.touchPath(file_md, false);
        try std.testing.expect(site.pages_to_generate.isSet(md_page.source_path.index()));
        try std.testing.expectEqualStrings("{ hi: 4 }", md_page.scanned.?.frontmatter.?);

        // Delete markdown file
        site.pages_to_generate.unsetAll(); // clear flags
        try site.source_root.deleteFile("file.md");
        try site.touchPath(file_md, false);
        try std.testing.expect(!site.pages_to_generate.isSet(md_page.source_path.index()));
        try std.testing.expect(md_page.scanned == null);
        try std.testing.expectEqual(null, site.getPage(file_md));
        try std.testing.expectEqual(Str.init_index, (try site.strs.intern("file.html")).index());
        try std.testing.expectEqual(Str.init_index, (try site.strs.intern("file")).index());

        // Recreate a markdown file
        site.pages_to_generate.unsetAll(); // clear flags
        try site.source_root.writeFile(.{ .sub_path = "file.md", .data = "{}\x02" });
        try site.touchPath(file_md, false);
        try std.testing.expect(site.pages_to_generate.isSet(md_page.source_path.index()));
        try std.testing.expectEqual(null, md_page.generated);
        try std.testing.expectEqualStrings("{}", md_page.scanned.?.frontmatter.?);
        try std.testing.expectEqualStrings("text/html", @tagName(md_page.scanned.?.mime_type));
    }

    // Perform page generations in a loop, until none are left to-do. We first
    // scan all pages in the queue, then generate output for all those pages.
    // The reason is that page generation might use `list!` to get metadata on
    // other pages that requires scanning them first.
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
    pub fn generatePages(self: *Site) !void {
        while (self.pages_to_generate.findFirstSet()) |page_index| {
            _ = self.tmp_arena_state.reset(.{ .retain_with_limit = 1024 * 1024 });
            const page = self.pages.at(page_index);
            page.mutex.lock();
            defer page.mutex.unlock();
            try self.pages_to_generate.setValue(self.allocator(), page_index, false);
            try generate(self, page);
            continue;
        }
    }

    fn initPage(self: *Site, source_path: Str, stat: std.fs.File.Stat) !void {
        // Find matching rule.
        const rule_index = try self.ruleForPath(source_path) orelse return;
        const rule = self.rules[rule_index];

        // Create page.
        const page = Site.Page{
            .mutex = std.Thread.Mutex{},
            .source_path = source_path,
            .rule_index = rule_index,
            .processing = rule.processing,
            .replace_tags = rule.replace_tags,
            .scanned = null,
            .generated = null,
        };

        const page_index: usize = self.pages.count();
        try self.pages.append(self.allocator(), page);
        _ = source_path.replaceIndex(page_index);

        // Update pattern-match cache.
        var patterns_matched = try self.ensurePatternsMatchedForPage(source_path);
        var list_patterns = self.list_patterns.constIterator(0);
        while (list_patterns.next()) |list_pattern| {
            const pattern = list_pattern.pattern;
            if (glob.match(pattern.bytes(), source_path.bytes())) {
                try patterns_matched.setValue(self.allocator(), pattern.index(), true);
            }
        }

        try self.scanPage(source_path, stat);
    }

    fn deletePage(self: *Site, source_path: Str) !void {
        const page = self.pages.at(source_path.index());
        var scanned = &(page.scanned orelse return);

        self.output_root.deleteFile(scanned.output_path.bytes()) catch |err| {
            if (err != error.FileNotFound) return err;
        };

        // Clear the page index on output and web strs, so that other pages
        // might reuse these without reporting a conflict.
        if (scanned.output_path != page.source_path) {
            _ = scanned.output_path.replaceIndex(Str.init_index);
        }
        if (scanned.web_path != page.source_path) {
            _ = scanned.web_path.replaceIndex(Str.init_index);
        }

        page.scanned = null;

        // Update dependents that might include content from or a link to
        // the deleted page.
        try generateDependents(self, page);
        return;
    }

    fn scanPage(self: *Site, source_path: Str, stat: std.fs.File.Stat) !void {
        const page_index = source_path.index();
        var page = self.pages.at(page_index);

        switch (stat.kind) {
            .file => {},
            .directory => {
                // Gracefully recover if a path has become a directory by the
                // time we scan it.
                return;
            },
            .sym_link => {
                // A symlink to a file (rather than a directory) creates
                // problems for file watching. We watch source directories, and
                // if the symlinked file is not in a watched directory, the
                // watcher will miss changes to the file.
                //
                // We could change the watching logic, either by watching
                // individual files if they live outside of the project, or
                // the parent directories of those files. Both approaches raise
                // new questions I'm not sure are worth answering.
                //
                // As long as we can't fully support symlinked files, including
                // in the watcher, I prefer disallowing symlinked files
                // entirely over supporting them partially.
                return self.errors.add(
                    source_path,
                    Error{ .source_file_is_symlink = source_path },
                );
            },
            .block_device,
            .character_device,
            .named_pipe,
            .unix_domain_socket,
            .whiteout,
            .door,
            .event_port,
            .unknown,
            => |kind| {
                return self.errors.add(
                    source_path,
                    Error{ .unsupported_source_file = .{
                        .source_path = source_path,
                        .kind = kind,
                    } },
                );
            },
        }

        // Calculate output path.
        const output_path = switch (page.processing) {
            .xml, .none => source_path,
            .markdown => blk: {
                var buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
                const output_path_bytes = try self.outputPathForMarkdownFile(&buffer, source_path);
                break :blk try self.strs.intern(output_path_bytes);
            },
        };

        // Calculate web path.
        const extension = std.fs.path.extension(output_path.bytes());
        const web_path = try self.strs.intern(webPathFromFilePath(output_path.bytes()));
        const old_web_path_index = web_path.index();
        if (old_web_path_index != Str.init_index and old_web_path_index != page_index) {
            const existing = self.pages.at(old_web_path_index);
            existing.mutex.lock();
            defer existing.mutex.unlock();
            return self.errors.add(source_path, Error{
                .conflicting_source_files = .{
                    .web_path = web_path,
                    .source_paths = .{ source_path, existing.source_path },
                },
            });
        }

        const arena = self.tmp_arena_state.allocator();
        const frontmatter = if (page.processing == .markdown)
            switch (try self.frontmatters.read(
                arena,
                self.platform,
                self.source_root,
                page.source_path,
            )) {
                .frontmatter => |frontmatter| frontmatter,
                .no_frontmatter => null,
                .file_not_found => return,
                .access_denied => return self.errors.add(
                    source_path,
                    Error{ .source_path_access_denied = source_path },
                ),
                .failed_to_parse => {
                    return self.errors.add(
                        source_path,
                        Error{ .invalid_frontmatter = source_path },
                    );
                },
            }
        else
            "{}";

        page.scanned = .{
            .output_path = output_path,
            .web_path = web_path,
            .mime_type = mime.extension_map.get(extension) orelse .@"application/octet-stream",
            .frontmatter = frontmatter,
        };

        _ = output_path.replaceIndex(page_index);
        _ = web_path.replaceIndex(page_index);

        try generateDependents(self, page);
        try self.pages_to_generate.setValue(
            self.allocator(),
            page.source_path.index(),
            true,
        );
    }

    fn generateDependents(self: *Site, page: *Page) !void {
        const self_page_index = page.source_path.index();
        var pattern_indexes = self.patterns_matched_by_page.at(self_page_index).iterator();
        while (pattern_indexes.next()) |pattern_index| {
            var page_uses = self.list_patterns.at(pattern_index).page_uses.iterator();
            while (page_uses.next()) |page_index| {
                try self.pages_to_generate.setValue(self.allocator(), page_index, true);
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

        // --- Rule-derived attributes ---
        rule_index: usize,
        replace_tags: []Str,
        processing: Processing,

        // --- Filesystem-derived attributes ---
        // output and web path are in this category for a future in which we
        // might want to perform content-addressable output names for some
        // paths.
        scanned: ?struct {
            output_path: Str,
            web_path: Str,
            mime_type: mime.Type,
            frontmatter: ?[]const u8,
        },

        generated: ?struct {
            output_len: u64,
        },
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
                if (matches.isSet(pattern_index)) {
                    const page = self.site.pages.at(page_index);
                    return if (page.scanned == null) continue else page;
                }
            }
            return null;
        }
    };

    fn ruleForPath(self: *Site, source_path: Str) !?usize {
        var matches: [10]usize = undefined;
        var len: u8 = 0;

        for (self.rules, 0..) |rule, rule_index| {
            if (!matchAny(rule.patterns, source_path.bytes())) continue;

            matches[len] = rule_index;
            len += 1;
            if (len > matches.len) break;
        }

        return switch (len) {
            1 => matches[0],
            0 => blk: {
                try self.errors.add(source_path, Error{
                    .no_rule_for_page = source_path,
                });
                break :blk null;
            },
            else => blk: {
                try self.errors.add(source_path, Error{
                    .conflicting_rules = .{
                        .source_path = source_path,
                        .rule_indices = .{ matches[0], matches[1] },
                    },
                });
                break :blk null;
            },
        };
    }

    test ruleForPath {
        var test_site = try TestSite.init(.{
            .markdown_patterns = &.{ "rule_one/*", "conflicting/*" },
            .static_patterns = &.{ "rule_two/*", "conflicting/*" },
        });
        defer test_site.deinit();
        var site = test_site.site;

        try std.testing.expectEqual(
            0,
            site.ruleForPath(try site.strs.intern("rule_one/file.txt")),
        );
        try std.testing.expectEqual(
            1,
            site.ruleForPath(try site.strs.intern("rule_two/file.txt")),
        );
        try std.testing.expectEqual(
            null,
            site.ruleForPath(try site.strs.intern("shared/file.txt")),
        );
        try std.testing.expectEqual(
            null,
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

    fn outputPathForMarkdownFile(self: *Site, buffer: []u8, path: Str) ![]const u8 {
        const path_bytes = path.bytes();
        if (!isMarkdown(path_bytes)) {
            try self.errors.add(path, Error{
                .markdown_rule_applied_to_non_markdown_file = path,
            });
        }
        return std.fmt.bufPrint(
            buffer,
            "{s}.html",
            .{path_bytes[0..(path_bytes.len - std.fs.path.extension(path_bytes).len)]},
        );
    }

    pub fn matchAny(patterns: []Str, path: []const u8) bool {
        for (patterns) |pattern| {
            if (glob.match(pattern.bytes(), path)) return true;
        } else {
            return false;
        }
    }

    pub fn iterator(self: *Site) Pages.Iterator {
        return self.pages.iterator(0);
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
    allocator: std.mem.Allocator,
    site: *Site,
    strs: Str.Registry,
    source_root: std.testing.TmpDir,
    output_root: std.testing.TmpDir,

    pub const Config = struct {
        markdown_patterns: []const []const u8 = &.{},
        static_patterns: []const []const u8 = &.{},
        ignore_patterns: []const []const u8 = &.{},
    };

    pub fn init(config: Config) !TestSite {
        if (!builtin.is_test) @panic("TestSite.init is intended for tests only");
        const allocator = std.testing.allocator;
        const source_tmpdir = std.testing.tmpDir(.{});
        const output_tmpdir = std.testing.tmpDir(.{});
        const strs = try Str.Registry.init(allocator);
        const site = try allocator.create(Site);
        site.* = try Site.init(
            allocator,
            source_tmpdir.dir,
            "build.roc",
            output_tmpdir.dir,
            strs,
        );

        var rules = std.ArrayList(Site.Rule).init(site.allocator());
        defer rules.deinit();
        if (config.markdown_patterns.len > 0) {
            try rules.append(Site.Rule{
                .processing = .markdown,
                .patterns = try strsFromSlices(site, config.markdown_patterns),
                .replace_tags = try strsFromSlices(site, &.{"dep"}),
            });
        }
        if (config.static_patterns.len > 0) {
            try rules.append(Site.Rule{
                .processing = .none,
                .patterns = try strsFromSlices(site, config.static_patterns),
                .replace_tags = try strsFromSlices(site, &.{}),
            });
        }
        site.rules = try rules.toOwnedSlice();
        if (config.ignore_patterns.len > 0) {
            const new_ignore_patterns = try site.allocator().alloc(
                Str,
                site.ignore_patterns.len + config.ignore_patterns.len,
            );
            for (site.ignore_patterns, 0..) |pattern, index| {
                new_ignore_patterns[index] = pattern;
            }
            for (config.ignore_patterns, site.ignore_patterns.len..) |pattern, index| {
                new_ignore_patterns[index] = try site.strs.intern(pattern);
            }
            site.ignore_patterns = new_ignore_patterns;
        }

        return TestSite{
            .allocator = allocator,
            .site = site,
            .strs = strs,
            .source_root = source_tmpdir,
            .output_root = output_tmpdir,
        };
    }

    pub fn deinit(self: *TestSite) void {
        self.site.deinit();
        self.strs.deinit();
        self.source_root.cleanup();
        self.output_root.cleanup();
        self.allocator.destroy(self.site);
    }

    fn strsFromSlices(site: *Site, slices: []const []const u8) ![]Str {
        var strings = try site.allocator().alloc(Str, slices.len);
        for (slices, 0..) |slice, index| {
            strings[index] = try site.strs.intern(slice);
        }
        return strings;
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
