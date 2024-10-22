const std = @import("std");
const builtin = @import("builtin");
const RocStr = @import("roc/str.zig").RocStr;
const RocList = @import("roc/list.zig").RocList;
const RocResult = @import("roc/result.zig").RocResult;
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

fn run() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var args = std.process.args();
    const roc_main_path = args.next() orelse return error.EmptyArgv;
    const project_path = std.fs.path.dirname(roc_main_path) orelse return error.NoProjectPath;

    try scanSourceFiles(allocator, project_path);
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

    try generateSite(allocator, "output");
}

fn scanSourceFiles(child_allocator: std.mem.Allocator, root_path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(child_allocator);
    const allocator = arena.allocator();
    const source_root = std.fs.cwd().openDir(root_path, .{ .iterate = true }) catch |err| {
        try failPrettily("Cannot access directory containing {s}: '{}'\n", .{ root_path, err });
    };
    var source_files = std.ArrayList([]const u8).init(allocator);
    var source_dirs = std.StringHashMap(void).init(allocator);
    var walker = try source_root.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (ignorePath(entry.path)) {
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

fn ignorePath(path: []const u8) bool {
    // TODO: add .gitignore behavior.
    return std.mem.eql(u8, path, ".git");
}

const RocPages = extern struct {
    dirs: RocList,
    files: RocList,
    processing: RocProcessing,
};

const RocProcessing = enum(u8) {
    markdown = 0,
    none = 1,
};

export fn roc_fx_copy(pages: *RocPages) callconv(.C) RocResult(void, void) {
    if (copy(pages)) {
        return .{ .payload = .{ .ok = void{} }, .tag = .RocOk };
    } else |err| {
        failCrudely(err);
    }
}

fn copy(pages: *RocPages) !void {
    // Process dirs.
    const dirs_len = pages.dirs.len();
    if (dirs_len > 0) {
        const elements = pages.dirs.elements(RocStr) orelse return error.RocListUnexpectedlyEmpty;
        for (elements, 0..dirs_len) |roc_str, _| {
            const path = dropLeadingSlash(roc_str.asSlice());
            try addFilesInDir(dropLeadingSlash(path), pages.processing);
        }
    }

    // Process files.
    const files_len = pages.files.len();
    if (files_len > 0) {
        const elements = pages.files.elements(RocStr) orelse return error.RocListUnexpectedlyEmpty;
        for (elements, 0..files_len) |roc_str, _| {
            const path = dropLeadingSlash(roc_str.asSlice());
            for (state.source_files.items, 0..) |candidate, index| {
                if (std.mem.eql(u8, candidate, path)) {
                    const file_path = try state.arena.allocator().dupe(u8, path);
                    break try addFile(file_path, index, pages.processing);
                }
            } else {
                try failPrettily("Can't read file '{s}'\n", .{path});
            }
        }
    }
}

fn addFilesInDir(dir_path: []const u8, processing: RocProcessing) !void {
    if (!state.source_dirs.contains(dir_path)) {
        try failPrettily("Can't read directory '{s}'\n", .{dir_path});
    }
    for (state.source_files.items, 0..) |file_path, index| {
        const file_dir = std.fs.path.dirname(file_path) orelse continue;
        if (std.mem.eql(u8, file_dir, dir_path)) {
            try addFile(file_path, index, processing);
        }
    }
}

fn addFile(source_path: []const u8, index: usize, processing: RocProcessing) !void {
    const destination_path = switch (processing) {
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

test "addFilesInDir: directory with source_files" {
    var tmpdir = std.testing.tmpDir(.{});
    defer tmpdir.cleanup();
    const root_path = try tmpdir.parent_dir.realpathAlloc(std.testing.allocator, &tmpdir.sub_path);
    defer std.testing.allocator.free(root_path);
    const project_dir = tmpdir.dir;

    try project_dir.makeDir("project");
    try project_dir.makeDir("project/subdir");
    try project_dir.writeFile(.{ .sub_path = "project/file.1", .data = &[_]u8{} });
    try project_dir.writeFile(.{ .sub_path = "project/file.2", .data = &[_]u8{} });
    try project_dir.writeFile(.{ .sub_path = "project/subdir/file.3", .data = &[_]u8{} });
    try project_dir.writeFile(.{ .sub_path = "file.4", .data = &[_]u8{} });

    try scanSourceFiles(std.testing.allocator, root_path);
    defer state.deinit();

    try addFilesInDir("project", .none);

    try expectDestinationFileForPath("project/file.1", "project/file.1");
    try expectDestinationFileForPath("project/file.2", "project/file.2");
    try expectDestinationFileForPath(null, "project/subdir/file.3");
    try expectDestinationFileForPath(null, "file.4");
}

test "addFilesInDir: non-existing directory" {
    var tmpdir = std.testing.tmpDir(.{});
    defer tmpdir.cleanup();
    const root_path = try tmpdir.parent_dir.realpathAlloc(std.testing.allocator, &tmpdir.sub_path);
    defer std.testing.allocator.free(root_path);
    try scanSourceFiles(std.testing.allocator, root_path);
    defer state.deinit();

    try std.testing.expectError(error.PrettyError, addFilesInDir("made-up", .none));
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

fn dropLeadingSlash(path: []const u8) []const u8 {
    if (path.len == 0) {
        return path;
    } else if (std.fs.path.isSep(path[0])) {
        return path[1..];
    } else {
        return path;
    }
}

test "dropLeadingSlash" {
    try std.testing.expectEqualStrings("", dropLeadingSlash(""));
    try std.testing.expectEqualStrings("foo/bar", dropLeadingSlash("/foo/bar"));
    try std.testing.expectEqualStrings("foo/bar", dropLeadingSlash("foo/bar"));
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

    const buffer = try allocator.alloc(u8, 1000);
    defer allocator.free(buffer);
    var fifo = std.fifo.LinearFifo(u8, .Slice).init(buffer);
    for (0..state.source_files.items.len) |index| {
        try generateSitePath(&fifo, output_dir, index);
    }
}

fn generateSitePath(fifo: anytype, output_dir: std.fs.Dir, index: usize) !void {
    // I'd like to use the below, but get the following error when I do:
    //     hidden symbol `__dso_handle' isn't defined
    // try state.source_root.copyFile(source_path, output_dir, destination_path, .{});

    const destination_path = state.destination_files.items[index] orelse return void{};
    const source_path = state.source_files.items[index];
    defer fifo.deinit();
    const from_file = try state.source_root.openFile(source_path, .{});
    defer from_file.close();
    const to_file = try output_dir.createFile(destination_path, .{ .truncate = true, .exclusive = true });
    defer to_file.close();
    try fifo.pump(from_file.reader(), to_file.writer());
}
