const std = @import("std");
const builtin = @import("builtin");
const RocStr = @import("roc/str.zig").RocStr;
const RocList = @import("roc/list.zig").RocList;
const RocResult = @import("roc/result.zig").RocResult;

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
    source_files: std.StringHashMap(u32),
    source_dirs: std.StringHashMap(void),
    destination_files: []?[]const u8,

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
    var source_files = std.StringHashMap(u32).init(allocator);
    var source_dirs = std.StringHashMap(void).init(allocator);
    var walker = try source_root.walk(allocator);
    defer walker.deinit();
    var next_id: u32 = 0;
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
            try source_files.put(try allocator.dupe(u8, entry.path), next_id);
            next_id += 1;
        }
    }
    const destination_files = try allocator.alloc(?[]const u8, next_id);
    @memset(destination_files, null);
    state = .{
        .arena = arena,
        .source_root = source_root,
        .source_files = source_files,
        .source_dirs = source_dirs,
        .destination_files = destination_files,
    };
}

fn ignorePath(path: []const u8) bool {
    // TODO: add .gitignore behavior.
    return std.mem.eql(u8, path, ".git");
}

const RocPages = extern struct {
    dirs: RocList,
    files: RocList,
    conversion: RocConversion,
};

const RocConversion = enum(u8) {
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
            try addFilesInDir(dropLeadingSlash(path));
        }
    }

    // Process files.
    const files_len = pages.files.len();
    if (files_len > 0) {
        const elements = pages.files.elements(RocStr) orelse return error.RocListUnexpectedlyEmpty;
        for (elements, 0..files_len) |roc_str, _| {
            const path = dropLeadingSlash(roc_str.asSlice());
            if (state.source_files.get(path)) |id| {
                state.destination_files[id] = try state.arena.allocator().dupe(u8, path);
            } else {
                try failPrettily("Can't read file '{s}'\n", .{path});
            }
        }
    }
}

fn addFilesInDir(dir_path: []const u8) !void {
    if (!state.source_dirs.contains(dir_path)) {
        try failPrettily("Can't read directory '{s}'\n", .{dir_path});
    }
    var source_file_iter = state.source_files.iterator();
    while (source_file_iter.next()) |entry| {
        const file_path = entry.key_ptr.*;
        if (std.fs.path.dirname(file_path)) |file_dir| {
            if (std.mem.eql(u8, file_dir, dir_path)) {
                state.destination_files[entry.value_ptr.*] = file_path;
            }
        }
    }
}

fn expectDestinationFileForPath(expected: ?[]const u8, path: []const u8) !void {
    const actual = state.destination_files[state.source_files.get(path).?];
    if (expected) |expected_string| {
        try std.testing.expectEqualStrings(expected_string, actual.?);
    } else {
        try std.testing.expectEqual(null, actual);
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

    try addFilesInDir("project");

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
    defer std.testing.allocator.free(state.destination_files);

    try std.testing.expectError(error.PrettyError, addFilesInDir("made-up"));
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

    const buffer = try allocator.alloc(u8, 1000);
    defer allocator.free(buffer);

    var source_dir_iter = state.source_dirs.keyIterator();
    while (source_dir_iter.next()) |dir_path| {
        try output_dir.makePath(dir_path.*);
    }

    var source_file_iter = state.source_files.iterator();
    while (source_file_iter.next()) |entry| {
        const source_path = entry.key_ptr.*;
        if (state.destination_files[entry.value_ptr.*]) |destination_path| {
            // I'd like to use the below, but get the following error when I do:
            //     hidden symbol `__dso_handle' isn't defined
            // try source_root.copyFile(source_path, output_dir, destination_path, .{});

            var fifo = std.fifo.LinearFifo(u8, .Slice).init(buffer);
            defer fifo.deinit();
            const from_file = try state.source_root.openFile(source_path, .{});
            defer from_file.close();
            const to_file = try output_dir.createFile(destination_path, .{ .truncate = true, .exclusive = true });
            defer to_file.close();
            try fifo.pump(from_file.reader(), to_file.writer());
        }
    }
}
