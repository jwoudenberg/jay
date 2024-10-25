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

extern fn roc__mainForHost_1_exposed_generic(*anyopaque) callconv(.C) void;
extern fn roc__mainForHost_1_exposed_size() callconv(.C) i64;
extern fn roc__mainForHost_0_caller(flags: *anyopaque, closure_data: *anyopaque, output: *RocResult(void, i32)) void;

const State = struct {
    arena: std.heap.ArenaAllocator,
    source_root: std.fs.Dir,
    source_files: std.ArrayList([]const u8),
    source_dirs: std.StringHashMap(void),
    destination_files: std.ArrayList(?[]const u8),
    processing: std.ArrayList(?RocProcessing),

    fn deinit(self: *State) void {
        self.arena.deinit();
    }
};
var state: State = undefined;

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

    try scanSourceFiles(allocator, roc_main_path, project_path);
    defer state.deinit();

    // call into roc
    const size = @as(usize, @intCast(roc__mainForHost_1_exposed_size()));
    const captures = roc_alloc(size, @alignOf(u128));
    defer roc_dealloc(captures, @alignOf(u128));

    var out: RocResult(void, i32) = .{
        .payload = .{ .ok = void{} },
        .tag = .RocOk,
    };

    roc__mainForHost_1_exposed_generic(captures);
    roc__mainForHost_0_caller(undefined, captures, &out);

    try generateSite(allocator, output_path);
}

fn scanSourceFiles(
    child_allocator: std.mem.Allocator,
    roc_main_path: []const u8,
    root_path: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(child_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();
    const source_root = std.fs.cwd().openDir(root_path, .{ .iterate = true }) catch |err| {
        try failPrettily("Cannot access directory containing {s}: '{}'\n", .{ root_path, err });
    };
    var source_files = std.ArrayList([]const u8).init(allocator);
    var source_dirs = std.StringHashMap(void).init(allocator);

    const relative_roc_main_path = try std.fs.path.relative(child_allocator, root_path, roc_main_path);
    defer child_allocator.free(relative_roc_main_path);

    var walker = try source_root.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (try dontScan(entry.path, relative_roc_main_path)) {
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
    const destination_files = std.ArrayList(?[]const u8).fromOwnedSlice(
        allocator,
        try allocator.alloc(?[]const u8, source_files.items.len),
    );
    @memset(destination_files.items, null);
    const processing = std.ArrayList(?RocProcessing).fromOwnedSlice(
        allocator,
        try allocator.alloc(?RocProcessing, source_files.items.len),
    );
    @memset(processing.items, null);
    state = .{
        .arena = arena,
        .source_root = source_root,
        .source_files = source_files,
        .source_dirs = source_dirs,
        .destination_files = destination_files,
        .processing = processing,
    };
}

fn dontScan(path: []const u8, relative_roc_main_path: []const u8) !bool {
    return std.mem.startsWith(u8, path, ".git") or
        std.mem.startsWith(u8, path, output_path) or
        std.mem.eql(u8, path, relative_roc_main_path) or
        std.mem.eql(u8, path, std.fs.path.stem(relative_roc_main_path));
}

const RocPages = extern struct {
    patterns: RocList,
    transforms: RocList,
    processing: RocProcessing,
};

const RocProcessing = enum(u8) {
    ignore = 0,
    markdown = 1,
    none = 2,
};

export fn roc_fx_copy(pages: *RocPages) callconv(.C) RocResult(void, void) {
    if (copy(pages)) {
        return .{ .payload = .{ .ok = void{} }, .tag = .RocOk };
    } else |err| {
        failCrudely(err);
    }
}

fn copy(pages: *RocPages) !void {
    const patterns_len = pages.patterns.len();
    if (patterns_len > 0) {
        const elements = pages.patterns.elements(RocStr) orelse return error.RocListUnexpectedlyEmpty;
        for (elements, 0..patterns_len) |roc_str, _| {
            try addFilesInPattern(roc_str.asSlice(), pages.processing);
        }
    }
}

fn addFilesInPattern(pattern: []const u8, processing: RocProcessing) !void {
    var none_matched = true;
    for (state.source_files.items, 0..) |file_path, index| {
        if (glob(pattern, file_path)) {
            none_matched = false;
            try addFile(file_path, index, processing);
        }
    }
    if (none_matched) {
        try failPrettily("The pattern '{s}' did not match any files", .{pattern});
    }
}

fn addFile(source_path: []const u8, index: usize, processing: RocProcessing) !void {
    const destination_path = switch (processing) {
        .ignore => null,
        .none => source_path,
        .markdown => try changeMarkdownExtension(state.arena.allocator(), source_path),
    };
    state.destination_files.items[index] = destination_path;
    state.processing.items[index] = processing;
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

fn expectDestinationFileForPath(expected: ?[]const u8, path: []const u8) !void {
    const destination_file = for (state.source_files.items, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate, path)) {
            break state.destination_files.items[index];
        }
    } else null;
    if (expected != null and destination_file != null) {
        try std.testing.expectEqualStrings(expected.?, destination_file.?);
    } else {
        try std.testing.expectEqual(expected, destination_file);
    }
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

fn generateSite(allocator: std.mem.Allocator, output_dir_path: []const u8) !void {
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
        try generateSitePath(allocator, &fifo, output_dir, index);
    }
}

fn unmappedFileError() !noreturn {
    if (builtin.is_test) return error.PrettyError;

    const stderr = std.io.getStdErr().writer();

    try stderr.print(
        \\Some source files are not matched by any rule.
        \\If you don't mean to include these in your site,
        \\you can ignore them like this:
        \\
        \\    Site.ignore!
        \\        [
        \\
    , .{});
    for (state.processing.items, 0..) |processing, index| {
        if (processing == null) {
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
    fifo: anytype,
    output_dir: std.fs.Dir,
    index: usize,
) !void {
    const processing = state.processing.items[index] orelse try unmappedFileError();
    const destination_path = state.destination_files.items[index] orelse return void{};
    const source_path = state.source_files.items[index];
    switch (processing) {
        .ignore => {},
        .none => {
            // I'd like to use the below, but get the following error when I do:
            //     hidden symbol `__dso_handle' isn't defined
            // try state.source_root.copyFile(source_path, output_dir, destination_path, .{});

            const from_file = try state.source_root.openFile(source_path, .{});
            defer from_file.close();
            const to_file = try output_dir.createFile(destination_path, .{ .truncate = true, .exclusive = true });
            defer to_file.close();
            try fifo.pump(from_file.reader(), to_file.writer());
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
            try to_file.writeAll(std.mem.span(html));
        },
    }
}
