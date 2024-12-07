// Contains the main data structure the host code is built around.

const std = @import("std");
const fail = @import("fail.zig");
const mime = @import("mime");
const Frontmatters = @import("frontmatter.zig").Frontmatters;
const glob = @import("glob.zig");
const Path = @import("path.zig").Path;

pub const Site = struct {
    // The allocator that should be used for content of the struct.
    arena_state: std.heap.ArenaAllocator,
    // Absolute path of the directory containing the static site project.
    source_root: std.fs.Dir,
    // basename of the .roc file we're currently running.
    roc_main: []const u8,
    // Path to the directory that will contain the generated site.
    output_root: []const u8,
    // Source patterns that should not be turned into pages.
    ignore_patterns: []const []const u8,
    // The page-construction rules defined in the .roc file we're running.
    rules: []Rule,
    // Interned path slices
    paths: *Path.Registry,
    // Stored frontmatters
    frontmatters: Frontmatters,

    // The pages in a project. Using arena-friendly datastructures that don't
    // reallocate when new pages are added.
    pages: std.SegmentedList(Page, 0),
    mutex: std.Thread.Mutex,

    pub fn init(
        gpa: std.mem.Allocator,
        cwd: std.fs.Dir,
        argv0: []const u8,
        output_root: []const u8,
        paths: *Path.Registry,
    ) !Site {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        const arena = arena_state.allocator();
        const source_root_path = std.fs.path.dirname(argv0) orelse "./";
        const source_root = cwd.openDir(source_root_path, .{}) catch |err| {
            try fail.prettily(
                "Cannot access directory containing {s}: '{}'\n",
                .{ source_root_path, err },
            );
        };
        const roc_main = std.fs.path.basename(argv0);
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
            .paths = paths,
            .frontmatters = Frontmatters.init(gpa),
            .pages = std.SegmentedList(Page, 0){},
            .mutex = std.Thread.Mutex{},
        };
    }

    const implicit_ignore_pattern_count = 3;

    pub fn user_ignore_patterns(self: *const Site) []const []const u8 {
        return self.ignore_patterns[implicit_ignore_pattern_count..];
    }

    pub fn deinit(self: *Site) void {
        self.frontmatters.deinit();
        self.arena_state.deinit();
    }

    // TODO: would be nice to remove this, avoid external access to allocator.
    pub fn allocator(self: *Site) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    pub fn openSourceRoot(self: *const Site, args: std.fs.Dir.OpenDirOptions) !std.fs.Dir {
        return self.source_root.openDir(".", args);
    }

    pub fn getPage(self: *Site, path: Path) ?*Page {
        self.mutex.lock();
        defer self.mutex.unlock();
        const page_index = path.index();
        if (page_index == Path.init_index) return null;
        const page = self.pages.at(page_index);
        page.mutex.lock();
        defer page.mutex.unlock();
        return if (page.deleted) null else page;
    }

    pub fn upsert(self: *Site, source_path: Path) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const opt_page: ?*Page = blk: {
            const page_index = source_path.index();
            break :blk if (page_index == Path.init_index) null else self.pages.at(page_index);
        };

        const stat = self.source_root.statFile(source_path.bytes()) catch |err| {
            if (err == error.FileNotFound) {
                if (opt_page) |page| {
                    page.mutex.lock();
                    defer page.mutex.unlock();
                    try self.delete(page);
                    return false;
                }
                return false;
            } else {
                return err;
            }
        };

        if (opt_page) |page| {
            page.mutex.lock();
            defer page.mutex.unlock();
            if (!page.deleted and page.last_modified == stat.mtime) {
                return false;
            } else {
                page.last_modified = stat.mtime;
                return self.update(page);
            }
        } else {
            try self.insert(stat, source_path);
            return true;
        }
    }

    test upsert {
        var tmpdir = std.testing.tmpDir(.{});
        defer tmpdir.cleanup();
        try tmpdir.dir.writeFile(.{ .sub_path = "file.md", .data = "{}\x02" });
        try tmpdir.dir.writeFile(.{ .sub_path = "style.css", .data = "" });

        var paths = Path.Registry.init(std.testing.allocator);
        defer paths.deinit();
        var site = try Site.init(std.testing.allocator, tmpdir.dir, "./build.roc", "output", &paths);
        defer site.deinit();
        var rules = [_]Site.Rule{
            Site.Rule{
                .processing = .markdown,
                .patterns = &.{"*.md"},
                .replace_tags = &.{ "tag1", "tag2" },
            },
            Site.Rule{
                .processing = .none,
                .patterns = &.{"*.css"},
                .replace_tags = &.{"tag3"},
            },
        };
        site.rules = &rules;

        // Insert markdown file.
        const file_md = try paths.intern("file.md");
        var generate = try site.upsert(file_md);
        const md_page = site.getPage(file_md).?;
        try std.testing.expect(generate);
        try std.testing.expect(!md_page.deleted);
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
        try std.testing.expectEqualStrings("{}", md_page.frontmatter);
        try std.testing.expectEqualStrings("text/html", @tagName(md_page.mime_type));

        // Insert static file.
        const style_css = try paths.intern("style.css");
        generate = try site.upsert(style_css);
        const css_page = site.getPage(style_css).?;
        try std.testing.expect(generate);
        try std.testing.expect(!css_page.deleted);
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
        try std.testing.expectEqualStrings("{}", css_page.frontmatter);
        try std.testing.expectEqualStrings("text/css", @tagName(css_page.mime_type));

        // Update markdown file without making changes.
        generate = try site.upsert(file_md);
        try std.testing.expect(!generate);
        try std.testing.expect(!md_page.deleted);

        // Update markdown file making changes.
        try tmpdir.dir.writeFile(.{ .sub_path = "file.md", .data = "{ hi: 4 }\x09" });
        generate = try site.upsert(file_md);
        try std.testing.expect(generate);
        try std.testing.expect(!md_page.deleted);
        try std.testing.expectEqualStrings("{ hi: 4 }", md_page.frontmatter);

        // Delete markdown file
        try tmpdir.dir.deleteFile("file.md");
        generate = try site.upsert(file_md);
        try std.testing.expect(!generate);
        try std.testing.expect(md_page.deleted);
        try std.testing.expectEqual(null, site.getPage(file_md));
        try std.testing.expectEqual(Path.init_index, (try paths.intern("file.html")).index());
        try std.testing.expectEqual(Path.init_index, (try paths.intern("file")).index());

        // Recreate a markdown file
        try tmpdir.dir.writeFile(.{ .sub_path = "file.md", .data = "{}\x02" });
        generate = try site.upsert(file_md);
        try std.testing.expect(generate);
        try std.testing.expect(!md_page.deleted);
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
        try std.testing.expectEqualStrings("{}", md_page.frontmatter);
        try std.testing.expectEqualStrings("text/html", @tagName(md_page.mime_type));

        try std.testing.expectEqual(2, site.pages.count());
    }

    fn insert(self: *Site, stat: std.fs.File.Stat, source_path: Path) !void {
        const page = Site.Page{
            .mutex = std.Thread.Mutex{},
            .source_path = source_path,
            .last_modified = stat.mtime,
            .output_len = null, // We'll know this when we generate the page
            .deleted = false,
            // Set in `setPageFields` helper:
            .frontmatter = undefined,
            .rule_index = undefined,
            .processing = undefined,
            .replace_tags = undefined,
            .mime_type = undefined,
            .output_path = undefined,
            .web_path = undefined,
        };

        // Copy the page into owned memory.
        const page_index: u32 = @intCast(self.pages.count());
        try self.pages.append(self.allocator(), page);
        try self.setPageFields(page_index);
    }

    fn update(self: *Site, page: *Page) !bool {
        var changed = false;

        if (page.deleted) {
            changed = true;
            page.deleted = false;
        }

        const old_output_path = page.output_path;
        const old_web_path = page.web_path;
        const old_frontmatter = page.frontmatter;
        try self.setPageFields(page.source_path.index());

        if (old_frontmatter.ptr != page.frontmatter.ptr) changed = true;
        if (old_output_path != page.output_path) changed = true;
        if (old_web_path != page.web_path) changed = true;

        return changed;
    }

    fn delete(self: *Site, page: *Page) !void {
        _ = self;
        page.deleted = true;
        // Clear the page index on output and web paths, so that other pages
        // might reuse these without reporting a conflict.
        _ = page.output_path.replaceIndex(Path.init_index);
        _ = page.web_path.replaceIndex(Path.init_index);
    }

    fn setPageFields(self: *Site, page_index: usize) !void {
        var page = self.pages.at(page_index);

        const rule_index = try self.ruleForPath(page.source_path);
        const rule = self.rules[rule_index];
        page.rule_index = rule_index;
        page.processing = rule.processing;
        page.replace_tags = rule.replace_tags;

        const source_path_bytes = page.source_path.bytes();
        page.output_path = switch (rule.processing) {
            .xml, .none => page.source_path,
            .markdown => blk: {
                var buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
                const output_path_bytes = try outputPathForMarkdownFile(&buffer, source_path_bytes);
                break :blk try self.paths.intern(output_path_bytes);
            },
        };

        const extension = std.fs.path.extension(page.output_path.bytes());
        page.mime_type = mime.extension_map.get(extension) orelse .@"application/octet-stream";
        page.web_path = try self.paths.intern(webPathFromFilePath(page.output_path.bytes()));

        _ = page.source_path.replaceIndex(page_index);
        _ = page.output_path.replaceIndex(page_index);
        const old_web_path_index = page.web_path.replaceIndex(page_index);
        if (old_web_path_index != Path.init_index and old_web_path_index != page_index) {
            const existing = self.pages.at(old_web_path_index);
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

        page.frontmatter = try self.frontmatters.read(self.source_root, page.source_path);
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
        last_modified: i128,
        deleted: bool,
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

    fn ruleForPath(site: *Site, source_path: Path) !usize {
        var matches: [10]usize = undefined;
        var len: u8 = 0;

        for (site.rules, 0..) |rule, rule_index| {
            if (!glob.matchAny(rule.patterns, source_path.bytes())) continue;

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
        var tmpdir = std.testing.tmpDir(.{});
        defer tmpdir.cleanup();
        var paths = Path.Registry.init(std.testing.allocator);
        defer paths.deinit();
        var site = try Site.init(std.testing.allocator, tmpdir.dir, "build.roc", "output", &paths);
        defer site.deinit();
        var rules = [_]Site.Rule{
            Site.Rule{
                .processing = .markdown,
                .patterns = &.{ "rule_one/*", "conflicting/*" },
                .replace_tags = &.{},
            },
            Site.Rule{
                .processing = .none,
                .patterns = &.{ "rule_two/*", "conflicting/*" },
                .replace_tags = &.{},
            },
        };
        site.rules = &rules;

        try std.testing.expectEqual(
            0,
            site.ruleForPath(try paths.intern("rule_one/file.txt")),
        );
        try std.testing.expectEqual(
            1,
            site.ruleForPath(try paths.intern("rule_two/file.txt")),
        );
        try std.testing.expectEqual(
            error.PrettyError,
            site.ruleForPath(try paths.intern("shared/file.txt")),
        );
        try std.testing.expectEqual(
            error.PrettyError,
            site.ruleForPath(try paths.intern("missing/file.txt")),
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
