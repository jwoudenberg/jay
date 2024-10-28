const std = @import("std");
const builtin = @import("builtin");
const RocStr = @import("roc/str.zig").RocStr;
const RocList = @import("roc/list.zig").RocList;
const glob = @import("glob.zig").glob;
const c = @cImport({
    @cInclude("cmark-gfm.h");
});

const State = struct {
    allocator: std.mem.Allocator,
    source_root: std.fs.Dir,
    source_files: std.ArrayList([]const u8),
    source_dirs: std.StringHashMap(void),
    ignored_paths: std.ArrayList([]const u8),
    destination_file_paths: std.ArrayList(?[]const u8),
    destination_file_rules: std.ArrayList(?PageRule),
};

const PageRule = struct {
    patterns: []const []const u8,
    processing: RocProcessing,
    content: []const Snippet,
};

const output_path = "output";

pub fn run(roc_pages: RocList) !void {
    var timer = std.time.Timer.start() catch unreachable;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = std.process.args();
    const argv0 = args.next() orelse return error.EmptyArgv;
    const project_path = std.fs.path.dirname(argv0) orelse return error.NoProjectPath;
    const roc_main_path = try std.fs.path.relative(allocator, project_path, argv0);

    var rules = try rocListMapToOwnedSlice(
        RocPages,
        PageRule,
        rocPagesToPageRule,
        allocator,
        roc_pages,
    );

    var state: State = undefined;

    if (rules.len == 1 and rules[0].processing == .bootstrap) {
        state = try scanSourceFiles(
            allocator,
            project_path,
            roc_main_path,
            bootstrap_ignore_patterns[0..],
        );
        rules = try bootstrap(gpa.allocator(), state, argv0);
    } else {
        const ignores = try getRuleIgnorePatterns(allocator, rules);
        state = try scanSourceFiles(
            allocator,
            project_path,
            roc_main_path,
            ignores,
        );
    }

    for (rules) |rule| {
        try planRule(allocator, &state, rule);
    }

    try generateSite(gpa.allocator(), state, output_path);

    const stdout = std.io.getStdOut().writer();
    try stdout.print("Generated site in {d}ms\n", .{timer.read() / 1_000_000});
}

fn bootstrap(
    gpa_allocator: std.mem.Allocator,
    state: State,
    roc_main_path: []const u8,
) ![]const PageRule {
    const rules = try bootstrapPageRules(gpa_allocator, state);
    try generateCodeForRules(roc_main_path, rules);
    return rules;
}

fn generateCodeForRules(roc_main_path: []const u8, rules: []const PageRule) !void {
    const cwd = std.fs.cwd();
    const file = try cwd.openFile(roc_main_path, .{ .mode = .read_write });
    defer file.close();

    // The size of my minimal bootstrap examples is 119 bytes at time of
    // writing. A file might contain some extra whitespace, but if it's much
    // larger than that then there's unexpected content in the file we don't
    // want to overwrite by accident.
    const stat = try file.stat();
    if (stat.size > 200) {
        try failPrettily(
            \\You're asking me to generate bootstrap code, which involves me
            \\replacing the code in main.roc.
            \\
            \\Your main.roc contains a bit more code than I expect and I don't
            \\want to accidentally delete anything important.
            \\
            \\If you're sure you want me to bootstrap delete everything from
            \\the main.roc file except:
            \\
            \\    app [main] {{ pf: platform "<dont change this part>" }}
            \\
            \\    import pf.Pages
            \\
            \\    main = Pages.bootstrap
            \\
        , .{});
    }

    // Find the end of the app header. We could truncate the entire file and
    // regenerate the app-header, but then we'd change the platform hash.
    var reader = file.reader();
    var end_of_app_declaration_offset: u64 = 0;
    while (reader.readByte() catch null) |byte| {
        end_of_app_declaration_offset += 1;
        if (byte == '}') break;
    }

    // We could truncate the file from the app header onwards before starting
    // to write, but the boostrapped code should always be longer than the code
    // we're replacing, or something is wrong. So instead of truncating we
    // instead check the file size before even getting to this point.
    var writer = file.writer();
    try writer.writeAll(
        \\
        \\
        \\import pf.Pages
        \\import pf.Html exposing [Html]
        \\
        \\main = [
        \\
    );
    for (rules) |rule| {
        switch (rule.processing) {
            .markdown => try writer.writeAll("    markdownFiles,\n"),
            .none => {
                try writer.writeAll(
                    \\    Pages.files [
                );
                for (rule.patterns, 0..) |pattern, index| {
                    try writer.print("\"{s}\"", .{pattern});
                    if (index < rule.patterns.len - 1) {
                        try writer.writeAll(", ");
                    }
                }
                try writer.writeAll(
                    \\],
                    \\
                );
            },
            .ignore => {
                try writer.writeAll(
                    \\    Pages.ignore [
                );
                for (rule.patterns, 0..) |pattern, index| {
                    try writer.print("\"{s}\"", .{pattern});
                    if (index < rule.patterns.len - 1) {
                        try writer.writeAll(", ");
                    }
                }
                try writer.writeAll(
                    \\],
                    \\
                );
            },
            .bootstrap => unreachable,
        }
    }
    try writer.writeAll(
        \\]
        \\
        \\
    );
    for (rules) |rule| {
        switch (rule.processing) {
            .markdown => {
                try writer.writeAll(
                    \\markdownFiles =
                    \\    Pages.files [
                );
                for (rule.patterns, 0..) |pattern, index| {
                    try writer.print("\"{s}\"", .{pattern});
                    if (index < rule.patterns.len - 1) {
                        try writer.writeAll(", ");
                    }
                }
                try writer.writeAll(
                    \\]
                    \\    |> Pages.fromMarkdown
                    \\    |> Pages.wrapHtml layout
                    \\
                    \\layout : Html -> Html
                    \\layout = \contents ->
                    \\    Html.html {} [
                    \\        Html.head {} [],
                    \\        Html.body {} [contents],
                    \\    ]
                    \\
                );
            },
            .none => {},
            .ignore => {},
            .bootstrap => unreachable,
        }
    }
}

test generateCodeForRules {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(.{ .sub_path = "main.roc", .data = 
    \\app [main] { pf: platform "some hash here" }
    \\
    \\import pf.Pages
    \\
    \\main = Pages.bootstrap
    });
    const rules = [_]PageRule{
        PageRule{
            .processing = .markdown,
            .patterns = ([_][]const u8{ "posts/*.md", "*.md" })[0..],
            .content = undefined,
        },
        PageRule{
            .processing = .none,
            .patterns = ([_][]const u8{"static"})[0..],
            .content = undefined,
        },
        PageRule{
            .processing = .ignore,
            .patterns = ([_][]const u8{ ".git", ".gitignore" })[0..],
            .content = undefined,
        },
    };
    const roc_main_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, "main.roc");
    defer std.testing.allocator.free(roc_main_path);
    try generateCodeForRules(roc_main_path, rules[0..]);
    const generated = try tmp_dir.dir.readFileAlloc(std.testing.allocator, "main.roc", 1024 * 1024);
    defer std.testing.allocator.free(generated);
    try std.testing.expectEqualStrings(generated,
        \\app [main] { pf: platform "some hash here" }
        \\
        \\import pf.Pages
        \\import pf.Html exposing [Html]
        \\
        \\main = [
        \\    markdownFiles,
        \\    Pages.files ["static"],
        \\    Pages.ignore [".git", ".gitignore"],
        \\]
        \\
        \\markdownFiles =
        \\    Pages.files ["posts/*.md", "*.md"]
        \\    |> Pages.fromMarkdown
        \\    |> Pages.wrapHtml layout
        \\
        \\layout : Html -> Html
        \\layout = \contents ->
        \\    Html.html {} [
        \\        Html.head {} [],
        \\        Html.body {} [contents],
        \\    ]
        \\
    );
}

fn bootstrapPageRules(gpa_allocator: std.mem.Allocator, state: State) ![]const PageRule {
    var arena = std.heap.ArenaAllocator.init(gpa_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var filetypes_by_dir = std.StringHashMap(std.StringHashMap(void)).init(allocator);
    for (state.source_files.items) |file_path| {
        const dirname = std.fs.path.dirname(file_path) orelse "";
        const extension = std.fs.path.extension(file_path);
        const result = try filetypes_by_dir.getOrPut(dirname);
        if (result.found_existing) {
            try result.value_ptr.put(extension, void{});
        } else {
            result.value_ptr.* = std.StringHashMap(void).init(allocator);
            try result.value_ptr.put(extension, void{});
        }
    }

    var markdown_patterns = std.ArrayList([]const u8).init(state.allocator);
    var static_patterns = std.ArrayList([]const u8).init(state.allocator);
    var filetypes_by_dir_iterator = filetypes_by_dir.iterator();
    while (filetypes_by_dir_iterator.next()) |entry| {
        const dir = entry.key_ptr.*;
        const extensions = entry.value_ptr;
        var extensions_iterator = extensions.keyIterator();
        while (extensions_iterator.next()) |extension| {
            const pattern =
                if (dir.len > 0)
                try std.fmt.allocPrint(
                    state.allocator,
                    "{s}/*{s}",
                    .{ dir, extension.* },
                )
            else
                try std.fmt.allocPrint(
                    state.allocator,
                    "*{s}",
                    .{extension.*},
                );
            if (isMarkdown(extension.*)) {
                try markdown_patterns.append(pattern);
            } else {
                try static_patterns.append(pattern);
            }
        }
    }

    var rules = try std.ArrayList(PageRule).initCapacity(state.allocator, 3);
    if (markdown_patterns.items.len > 0) {
        try rules.append(PageRule{
            .patterns = try markdown_patterns.toOwnedSlice(),
            .processing = .markdown,
            .content = blk: {
                const snippets = try state.allocator.alloc(Snippet, 1);
                snippets[0] = .source_contents;
                break :blk snippets;
            },
        });
    }
    if (static_patterns.items.len > 0) {
        try rules.append(PageRule{
            .patterns = try static_patterns.toOwnedSlice(),
            .processing = .none,
            .content = blk: {
                const snippets = try state.allocator.alloc(Snippet, 1);
                snippets[0] = .source_contents;
                break :blk snippets;
            },
        });
    }
    try rules.append(PageRule{
        .patterns = state.ignored_paths.items,
        .processing = .ignore,
        .content = try state.allocator.alloc(Snippet, 0),
    });
    return rules.items;
}

fn compareStrings(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs).compare(std.math.CompareOperator.lt);
}

test bootstrapPageRules {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var state = State{
        .allocator = allocator,
        .source_root = undefined,
        .source_files = std.ArrayList([]const u8).init(allocator),
        .source_dirs = std.StringHashMap(void).init(allocator),
        .ignored_paths = std.ArrayList([]const u8).init(allocator),
        .destination_file_paths = undefined,
        .destination_file_rules = undefined,
    };
    try state.source_files.append("markdown_only/one.md");
    try state.source_files.append("markdown_only/two.md");
    try state.source_files.append("static_only/main.css");
    try state.source_files.append("static_only/logo.png");
    try state.source_files.append("mixed/three.md");
    try state.source_files.append("mixed/rss.xml");
    try state.source_files.append("index.md");
    try state.ignored_paths.append(".gitignore");

    const rules = try bootstrapPageRules(std.testing.allocator, state);

    try std.testing.expectEqual(3, rules.len);

    try std.testing.expectEqual(.markdown, rules[0].processing);
    try std.testing.expectEqualSlices(Snippet, ([1]Snippet{.source_contents})[0..], rules[0].content);
    try std.testing.expectEqual(3, rules[0].patterns.len);
    const markdown_patterns = try std.testing.allocator.dupe([]const u8, rules[0].patterns);
    defer std.testing.allocator.free(markdown_patterns);
    std.sort.insertion([]const u8, markdown_patterns, {}, compareStrings);
    try std.testing.expectEqualStrings("*.md", markdown_patterns[0]);
    try std.testing.expectEqualStrings("markdown_only/*.md", markdown_patterns[1]);
    try std.testing.expectEqualStrings("mixed/*.md", markdown_patterns[2]);

    try std.testing.expectEqual(.none, rules[1].processing);
    try std.testing.expectEqualSlices(Snippet, ([1]Snippet{.source_contents})[0..], rules[1].content);
    try std.testing.expectEqual(3, rules[1].patterns.len);
    const static_patterns = try std.testing.allocator.dupe([]const u8, rules[1].patterns);
    defer std.testing.allocator.free(static_patterns);
    std.sort.insertion([]const u8, static_patterns, {}, compareStrings);
    try std.testing.expectEqualStrings("mixed/*.xml", static_patterns[0]);
    try std.testing.expectEqualStrings("static_only/*.css", static_patterns[1]);
    try std.testing.expectEqualStrings("static_only/*.png", static_patterns[2]);

    try std.testing.expectEqual(.ignore, rules[2].processing);
    try std.testing.expectEqualSlices(Snippet, ([0]Snippet{})[0..], rules[2].content);
    try std.testing.expectEqual(1, rules[2].patterns.len);
    try std.testing.expectEqualStrings(".gitignore", rules[2].patterns[0]);
}

fn scanSourceFiles(
    allocator: std.mem.Allocator,
    project_path: []const u8,
    roc_main_path: []const u8,
    explicit_ignores: []const []const u8,
) !State {
    const source_root = std.fs.cwd().openDir(project_path, .{ .iterate = true }) catch |err| {
        try failPrettily("Cannot access directory containing {s}: '{}'\n", .{ project_path, err });
    };
    var source_files = std.ArrayList([]const u8).init(allocator);
    var ignored_paths = std.ArrayList([]const u8).init(allocator);
    var source_dirs = std.StringHashMap(void).init(allocator);
    const implicit_ignores = try getImplicitIgnorePatterns(roc_main_path);

    var walker = try source_root.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        const ignore_implicitly = skipInScan(&implicit_ignores, entry.path);
        const ignore_explicitly = skipInScan(explicit_ignores, entry.path);
        if (ignore_explicitly) {
            try ignored_paths.append(try allocator.dupe(u8, entry.path));
        }
        if (ignore_implicitly or ignore_explicitly) {
            if (entry.kind == .directory) {
                // Reaching into the walker internals here to skip an entire
                // directory, similar to how the walker implementation does
                // this itself in a couple of places. This avoids needing to
                // iterate through potentially large amounts of ignored files,
                // for instance a .git directory.
                var item = walker.stack.pop();
                if (walker.stack.items.len != 0) {
                    item.iter.dir.close();
                }
            }
        } else if (entry.kind == .directory) {
            try source_dirs.put(try allocator.dupe(u8, entry.path), void{});
        } else if (entry.kind == .file) {
            try source_files.append(try allocator.dupe(u8, entry.path));
        }
    }
    const destination_file_paths = std.ArrayList(?[]const u8).fromOwnedSlice(
        allocator,
        try allocator.alloc(?[]const u8, source_files.items.len),
    );
    @memset(destination_file_paths.items, null);
    const destination_file_rules = std.ArrayList(?PageRule).fromOwnedSlice(
        allocator,
        try allocator.alloc(?PageRule, source_files.items.len),
    );
    @memset(destination_file_rules.items, null);
    return .{
        .allocator = allocator,
        .source_root = source_root,
        .source_files = source_files,
        .ignored_paths = ignored_paths,
        .source_dirs = source_dirs,
        .destination_file_paths = destination_file_paths,
        .destination_file_rules = destination_file_rules,
    };
}

fn skipInScan(ignore_patterns: []const []const u8, path: []const u8) bool {
    for (ignore_patterns) |pattern| {
        if (glob(pattern, path)) return true;
    } else {
        return false;
    }
}

// Read ignore patterns out of the page rules read from code.
fn getRuleIgnorePatterns(
    allocator: std.mem.Allocator,
    rules: []const PageRule,
) ![]const []const u8 {
    var ignore_patterns = std.ArrayList([]const u8).init(allocator);
    for (rules) |rule| {
        if (rule.processing == .ignore) {
            try ignore_patterns.appendSlice(rule.patterns);
        }
    }
    return ignore_patterns.toOwnedSlice();
}

// The Roc file that starts this script as well as anything we generate should
// be ignored implicitly, i.e. the user should not need to specify these.
fn getImplicitIgnorePatterns(roc_main_path: []const u8) ![3][]const u8 {
    return .{
        output_path,
        roc_main_path,
        std.fs.path.stem(roc_main_path),
    };
}

// When running the bootstrap script we have to guess which files the user
// might want to be ignored. This is our list of such guesses.
const bootstrap_ignore_patterns = [_][]const u8{
    ".git",
    ".gitignore",
    "README*",
};

const RocPages = extern struct {
    content: RocList,
    patterns: RocList,
    processing: RocProcessing,
};

const RocProcessing = enum(u8) {
    bootstrap = 0,
    ignore = 1,
    markdown = 2,
    none = 3,
};

const Snippet = union(enum) {
    snippet: []const u8,
    source_contents: void,
};

const RocContent = extern struct { payload: RocContentPayload, tag: RocContentTag };

const RocContentPayload = extern union {
    snippet: RocList,
    source_contents: void,
};

const RocContentTag = enum(u8) {
    RocSnippet = 0,
    RocSourceFile = 1,
};

fn rocPagesToPageRule(allocator: std.mem.Allocator, pages: RocPages) !PageRule {
    return .{
        .patterns = try rocListMapToOwnedSlice(
            RocStr,
            []const u8,
            fromRocPattern,
            allocator,
            pages.patterns,
        ),
        .processing = pages.processing,
        .content = try rocListMapToOwnedSlice(
            RocContent,
            Snippet,
            fromRocContent,
            allocator,
            pages.content,
        ),
    };
}

fn fromRocPattern(allocator: std.mem.Allocator, roc_pattern: RocStr) ![]const u8 {
    return try allocator.dupe(u8, roc_pattern.asSlice());
}

fn planRule(allocator: std.mem.Allocator, state: *State, rule: PageRule) !void {
    for (rule.patterns) |pattern| {
        try addFilesInPattern(allocator, state, rule, pattern);
    }
}

fn fromRocContent(allocator: std.mem.Allocator, roc_content: RocContent) !Snippet {
    return switch (roc_content.tag) {
        .RocSourceFile => .source_contents,
        .RocSnippet => {
            const snippet = try rocListCopyToOwnedSlice(
                u8,
                allocator,
                roc_content.payload.snippet,
            );
            return .{ .snippet = snippet };
        },
    };
}

fn RocListIterator(comptime T: type) type {
    return struct {
        const Self = @This();

        elements: ?[*]T,
        len: usize,
        index: usize,

        fn init(list: RocList) Self {
            return Self{
                .elements = list.elements(T),
                .len = list.len(),
                .index = 0,
            };
        }

        fn next(self: *Self) ?T {
            if (self.index < self.len) {
                const elem = self.elements.?[self.index];
                self.index += 1;
                return elem;
            } else {
                return null;
            }
        }
    };
}

fn rocListMapToOwnedSlice(
    comptime T: type,
    comptime O: type,
    comptime map: fn (allocator: std.mem.Allocator, elem: T) anyerror!O,
    allocator: std.mem.Allocator,
    list: RocList,
) ![]const O {
    const len = list.len();
    if (len == 0) return allocator.alloc(O, 0);
    const elements = list.elements(T) orelse return error.RocListUnexpectedlyEmpty;
    const slice = try allocator.alloc(O, len);
    for (elements, 0..len) |element, index| {
        slice[index] = try map(allocator, element);
    }
    return slice;
}

fn rocListCopyToOwnedSlice(
    comptime T: type,
    allocator: std.mem.Allocator,
    list: RocList,
) ![]const T {
    const len = list.len();
    if (len == 0) return allocator.alloc(T, 0);
    const elements = list.elements(T) orelse return error.RocListUnexpectedlyEmpty;
    const slice = try allocator.alloc(T, len);
    for (elements, 0..len) |element, index| {
        slice[index] = element;
    }
    return slice;
}

fn addFilesInPattern(
    allocator: std.mem.Allocator,
    state: *State,
    rule: PageRule,
    pattern: []const u8,
) !void {
    if (rule.processing == .ignore) return;

    var none_matched = true;
    for (state.source_files.items, 0..) |file_path, index| {
        if (glob(pattern, file_path)) {
            none_matched = false;
            try addFile(allocator, state, rule, file_path, index);
        }
    }
    if (none_matched) {
        try failPrettily("The pattern '{s}' did not match any files", .{pattern});
    }
}

fn addFile(
    allocator: std.mem.Allocator,
    state: *State,
    rule: PageRule,
    source_path: []const u8,
    index: usize,
) !void {
    const destination_path = switch (rule.processing) {
        .ignore => return error.UnexpectedlyAskedToAddIgnoredFile,
        .bootstrap => return error.UnexpectedlyAskedToAddFileForBootstrapRule,
        .none => source_path,
        .markdown => try changeMarkdownExtension(allocator, source_path),
    };
    state.destination_file_paths.items[index] = destination_path;
    state.destination_file_rules.items[index] = rule;
}

fn changeMarkdownExtension(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const extension = std.fs.path.extension(path);
    if (!isMarkdown(extension)) {
        try failPrettily("You're asking me to process a file as markdown, but it does not have a markdown file extension: {s}", .{path});
    }
    return std.fmt.allocPrint(
        allocator,
        "{s}.html",
        .{path[0..(path.len - extension.len)]},
    );
}

test changeMarkdownExtension {
    const actual = try changeMarkdownExtension(std.testing.allocator, "file.md");
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("file.html", actual);

    try std.testing.expectError(error.PrettyError, changeMarkdownExtension(
        std.testing.allocator,
        "file.txt",
    ));
}

fn checkForMarkdownExtension(path: []const u8) ![]const u8 {
    const extension = std.fs.path.extension(path);
    if (isMarkdown(extension)) {
        return extension;
    } else {
        try failPrettily("You're asking me to process a file as markdown, but it does not have a markdown file extension: {s}", .{path});
    }
}

fn isMarkdown(extension: []const u8) bool {
    return std.ascii.eqlIgnoreCase(extension, ".md") or
        std.ascii.eqlIgnoreCase(extension, ".markdown");
}

test isMarkdown {
    try std.testing.expect(isMarkdown(".md"));
    try std.testing.expect(isMarkdown(".MD"));
    try std.testing.expect(isMarkdown(".MarkDown"));
    try std.testing.expect(!isMarkdown("file.txt"));
}

// For use in situations where we want to show a pretty helpful error.
// 'pretty' is relative, much work to do here to really live up to that.
pub fn failPrettily(comptime format: []const u8, args: anytype) !noreturn {
    if (!builtin.is_test) {
        const stderr = std.io.getStdErr().writer();
        try stderr.print(format, args);
    }
    return error.PrettyError;
}

// For use in theoretically-possible-but-unlikely scenarios that we don't want
// to write dedicated error messages for.
pub fn failCrudely(err: anyerror) noreturn {
    // Make sure we only print if we didn't already show a pretty error.
    if (err != error.PrettyError) {
        failPrettily("Error: {}", .{err}) catch {};
    }
    std.process.exit(1);
}

fn generateSite(
    gpa_allocator: std.mem.Allocator,
    state: State,
    output_dir_path: []const u8,
) !void {
    // Clear output directory if it already exists.
    state.source_root.deleteTree(output_dir_path) catch |err| {
        if (err != error.NotDir) {
            return err;
        }
    };
    try state.source_root.makeDir(output_dir_path);
    var output_dir = try state.source_root.openDir(output_dir_path, .{});
    defer output_dir.close();

    var source_dir_iter = state.source_dirs.keyIterator();
    while (source_dir_iter.next()) |dir_path| {
        try output_dir.makePath(dir_path.*);
    }

    var arena = std.heap.ArenaAllocator.init(gpa_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for (0..state.source_files.items.len) |index| {
        try generateSitePath(allocator, state, output_dir, index);
        _ = arena.reset(.retain_capacity);
    }
}

fn unmappedFileError(state: State) !noreturn {
    if (builtin.is_test) return error.PrettyError;

    const stderr = std.io.getStdErr().writer();

    try stderr.print(
        \\Some source files are not matched by any rule.
        \\If you don't mean to include these in your site,
        \\you can ignore them like this:
        \\
        \\    Site.ignore
        \\        [
        \\
    , .{});
    for (state.destination_file_paths.items, 0..) |path, index| {
        if (path == null) {
            const source_path = state.source_files.items[index];
            try stderr.print("            \"{s}\",\n", .{source_path});
        }
    }
    try stderr.print(
        \\        ]
    , .{});

    return error.PrettyError;
}

fn generateSitePath(
    allocator: std.mem.Allocator,
    state: State,
    output_dir: std.fs.Dir,
    index: usize,
) !void {
    const destination_path = state.destination_file_paths.items[index] orelse try unmappedFileError(state);
    const rule = state.destination_file_rules.items[index] orelse return error.MissingPageRule;
    const source_path = state.source_files.items[index];
    switch (rule.processing) {
        .ignore => return error.UnexpectedlyAskedToGenerateOutputForIgnoredFile,
        .bootstrap => return error.UnexpectedlyAskedToGenerateOutputForBootstrapRule,
        .none => {
            // I'd like to use the below, but get the following error when I do:
            //     hidden symbol `__dso_handle' isn't defined
            // try state.source_root.copyFile(source_path, output_dir, destination_path, .{});

            const buffer = try allocator.alloc(u8, 1024);
            defer state.allocator.free(buffer);
            var fifo = std.fifo.LinearFifo(u8, .Slice).init(buffer);
            defer fifo.deinit();

            const from_file = try state.source_root.openFile(source_path, .{});
            defer from_file.close();
            const to_file = try output_dir.createFile(destination_path, .{ .truncate = true, .exclusive = true });
            defer to_file.close();
            for (rule.content) |content_elem| {
                switch (content_elem) {
                    .source_contents => try fifo.pump(from_file.reader(), to_file.writer()),
                    .snippet => try to_file.writeAll(content_elem.snippet),
                }
            }
        },
        .markdown => {
            // TODO: figure out what to do if markdown files are larger than this.
            const markdown = try state.source_root.readFileAlloc(allocator, source_path, 1024 * 1024);
            defer allocator.free(markdown);
            const html = c.cmark_markdown_to_html(
                @ptrCast(markdown),
                markdown.len,
                c.CMARK_OPT_DEFAULT | c.CMARK_OPT_UNSAFE,
            ) orelse return error.OutOfMemory;
            defer std.c.free(html);
            const to_file = try output_dir.createFile(destination_path, .{ .truncate = true, .exclusive = true });
            defer to_file.close();
            for (rule.content) |xml| {
                switch (xml) {
                    .source_contents => try to_file.writeAll(std.mem.span(html)),
                    .snippet => try to_file.writeAll(xml.snippet),
                }
            }
        },
    }
}
