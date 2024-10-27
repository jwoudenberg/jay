const std = @import("std");
const builtin = @import("builtin");
const RocStr = @import("roc/str.zig").RocStr;
const RocList = @import("roc/list.zig").RocList;
const RocResult = @import("roc/result.zig").RocResult;
const glob = @import("glob.zig").glob;
const c = @cImport({
    @cInclude("cmark-gfm.h");
});

export fn roc_alloc(size: usize, alignment: u32) callconv(.C) *anyopaque {
    _ = alignment;
    return std.c.malloc(size).?;
}

export fn roc_realloc(old_ptr: *anyopaque, new_size: usize, old_size: usize, alignment: u32) callconv(.C) ?*anyopaque {
    _ = old_size;
    _ = alignment;
    return std.c.realloc(old_ptr, new_size);
}

export fn roc_dealloc(c_ptr: *anyopaque, alignment: u32) callconv(.C) void {
    _ = alignment;
    std.c.free(c_ptr);
}

export fn roc_panic(msg: *RocStr, tag_id: u32) callconv(.C) void {
    failPrettily("\n\nRoc crashed with the following error;\nMSG:{s}\nTAG:{d}\n\nShutting down\n", .{ msg.asSlice(), tag_id }) catch {};
    std.process.exit(1);
}

export fn roc_dbg(loc: *RocStr, msg: *RocStr, src: *RocStr) callconv(.C) void {
    if (!builtin.is_test) {
        const stderr = std.io.getStdErr().writer();
        stderr.print("[{s}] {s} = {s}\n", .{ loc.asSlice(), src.asSlice(), msg.asSlice() }) catch unreachable;
    }
}

export fn roc_memset(dst: [*]u8, value: i32, size: usize) callconv(.C) void {
    return @memset(dst[0..size], @intCast(value));
}

fn roc_getppid() callconv(.C) c_int {
    // Only recently added to Zig: https://github.com/ziglang/zig/pull/20866
    return @bitCast(@as(u32, @truncate(std.os.linux.syscall0(.getppid))));
}

fn roc_getppid_windows_stub() callconv(.C) c_int {
    return 0;
}

fn roc_shm_open(name: [*:0]const u8, oflag: c_int, mode: c_uint) callconv(.C) c_int {
    return std.c.shm_open(name, oflag, mode);
}

fn roc_mmap(addr: ?*align(std.mem.page_size) anyopaque, length: usize, prot: c_uint, flags: std.c.MAP, fd: c_int, offset: c_int) callconv(.C) *anyopaque {
    return std.c.mmap(addr, length, prot, flags, fd, offset);
}

comptime {
    if (builtin.os.tag == .macos or builtin.os.tag == .linux) {
        @export(roc_getppid, .{ .name = "roc_getppid", .linkage = .strong });
        @export(roc_mmap, .{ .name = "roc_mmap", .linkage = .strong });
        @export(roc_shm_open, .{ .name = "roc_shm_open", .linkage = .strong });
    }

    if (builtin.os.tag == .windows) {
        @export(roc_getppid_windows_stub, .{ .name = "roc_getppid", .linkage = .strong });
    }
}

extern fn roc__mainForHost_1_exposed_generic(*RocList, *anyopaque) callconv(.C) void;

const State = struct {
    arena: std.heap.ArenaAllocator,
    source_root: std.fs.Dir,
    source_files: std.ArrayList([]const u8),
    source_dirs: std.StringHashMap(void),
    destination_file_paths: std.ArrayList(?[]const u8),
    destination_file_rules: std.ArrayList(?PageRule),

    fn deinit(self: *State) void {
        self.arena.deinit();
    }
};

const PageRule = struct {
    patterns: []const []const u8,
    processing: RocProcessing,
    content: []const Snippet,
};

pub fn main() void {
    if (run()) {
        const stdout = std.io.getStdOut().writer();
        stdout.print("Bye!\n", .{}) catch unreachable;
    } else |err| {
        failCrudely(err);
    }
}

const output_path = "output";

fn run() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var args = std.process.args();
    const roc_main_path = args.next() orelse return error.EmptyArgv;
    const project_path = std.fs.path.dirname(roc_main_path) orelse return error.NoProjectPath;

    var roc_pages: RocList = RocList{ .bytes = null, .length = 0, .capacity_or_alloc_ptr = 0 };
    roc__mainForHost_1_exposed_generic(&roc_pages, undefined);

    const rules = try rocListMapToOwnedSlice(
        RocPages,
        PageRule,
        rocPagesToPageRule,
        allocator,
        roc_pages,
    );

    const ignore_patterns = try getIgnorePatterns(allocator, rules, project_path, roc_main_path);
    var state = try scanSourceFiles(allocator, project_path, ignore_patterns);
    defer state.deinit();

    for (rules) |rule| {
        try planRule(&state, rule);
    }

    try generateSite(allocator, state, output_path);
}

fn scanSourceFiles(
    child_allocator: std.mem.Allocator,
    project_path: []const u8,
    ignore_patterns: []const []const u8,
) !State {
    var arena = std.heap.ArenaAllocator.init(child_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();
    const source_root = std.fs.cwd().openDir(project_path, .{ .iterate = true }) catch |err| {
        try failPrettily("Cannot access directory containing {s}: '{}'\n", .{ project_path, err });
    };
    var source_files = std.ArrayList([]const u8).init(allocator);
    var source_dirs = std.StringHashMap(void).init(allocator);

    var walker = try source_root.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (skipInScan(ignore_patterns, entry.path)) {
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
        .arena = arena,
        .source_root = source_root,
        .source_files = source_files,
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

fn getIgnorePatterns(
    allocator: std.mem.Allocator,
    rules: []const PageRule,
    project_path: []const u8,
    roc_main_path: []const u8,
) ![]const []const u8 {
    var ignore_patterns = std.ArrayList([]const u8).init(allocator);

    const relative_roc_main_path = try std.fs.path.relative(allocator, project_path, roc_main_path);
    const default_ignores = [_][]const u8{
        ".git",
        output_path,
        relative_roc_main_path,
        std.fs.path.stem(relative_roc_main_path),
    };
    try ignore_patterns.appendSlice(&default_ignores);

    for (rules) |rule| {
        if (rule.processing == .ignore) {
            try ignore_patterns.appendSlice(rule.patterns);
        }
    }
    return ignore_patterns.toOwnedSlice();
}

const RocPages = extern struct {
    content: RocList,
    patterns: RocList,
    processing: RocProcessing,
};

const RocProcessing = enum(u8) {
    ignore = 0,
    markdown = 1,
    none = 2,
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

fn planRule(state: *State, rule: PageRule) !void {
    for (rule.patterns) |pattern| {
        try addFilesInPattern(state, rule, pattern);
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

fn addFilesInPattern(state: *State, rule: PageRule, pattern: []const u8) !void {
    if (rule.processing == .ignore) return;

    var none_matched = true;
    for (state.source_files.items, 0..) |file_path, index| {
        if (glob(pattern, file_path)) {
            none_matched = false;
            try addFile(state, rule, file_path, index);
        }
    }
    if (none_matched) {
        try failPrettily("The pattern '{s}' did not match any files", .{pattern});
    }
}

fn addFile(state: *State, rule: PageRule, source_path: []const u8, index: usize) !void {
    const destination_path = switch (rule.processing) {
        .ignore => null,
        .none => source_path,
        .markdown => try changeMarkdownExtension(state.arena.allocator(), source_path),
    };
    state.destination_file_paths.items[index] = destination_path;
    state.destination_file_rules.items[index] = rule;
}

fn changeMarkdownExtension(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const extension = try checkForMarkdownExtension(path);
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
    if (std.ascii.eqlIgnoreCase(extension, ".md") or
        std.ascii.eqlIgnoreCase(extension, ".markdown"))
    {
        return extension;
    } else {
        try failPrettily("You're asking me to process a file as markdown, but it does not have a markdown file extension: {s}", .{path});
    }
}

test checkForMarkdownExtension {
    try std.testing.expectEqualStrings(".md", try checkForMarkdownExtension("file.md"));
    try std.testing.expectEqualStrings(".MD", try checkForMarkdownExtension("file.MD"));
    try std.testing.expectEqualStrings(".MarkDown", try checkForMarkdownExtension("file.MarkDown"));
    try std.testing.expectError(error.PrettyError, checkForMarkdownExtension("file.txt"));
}

// For use in situations where we want to show a pretty helpful error.
// 'pretty' is relative, much work to do here to really live up to that.
fn failPrettily(comptime format: []const u8, args: anytype) !noreturn {
    if (!builtin.is_test) {
        const stderr = std.io.getStdErr().writer();
        try stderr.print(format, args);
    }
    return error.PrettyError;
}

// For use in theoretically-possible-but-unlikely scenarios that we don't want
// to write dedicated error messages for.
fn failCrudely(err: anyerror) noreturn {
    // Make sure we only print if we didn't already show a pretty error.
    if (err != error.PrettyError) {
        failPrettily("Error: {}", .{err}) catch {};
    }
    std.process.exit(1);
}

fn generateSite(allocator: std.mem.Allocator, state: State, output_dir_path: []const u8) !void {
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

    const buffer = try allocator.alloc(u8, 1024);
    defer allocator.free(buffer);
    var fifo = std.fifo.LinearFifo(u8, .Slice).init(buffer);
    defer fifo.deinit();
    for (0..state.source_files.items.len) |index| {
        try generateSitePath(allocator, state, &fifo, output_dir, index);
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
    fifo: anytype,
    output_dir: std.fs.Dir,
    index: usize,
) !void {
    const destination_path = state.destination_file_paths.items[index] orelse try unmappedFileError(state);
    const rule = state.destination_file_rules.items[index] orelse return error.MissingPageRule;
    const source_path = state.source_files.items[index];
    switch (rule.processing) {
        .ignore => {},
        .none => {
            // I'd like to use the below, but get the following error when I do:
            //     hidden symbol `__dso_handle' isn't defined
            // try state.source_root.copyFile(source_path, output_dir, destination_path, .{});

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
