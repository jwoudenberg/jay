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
    const stderr = std.io.getStdErr().writer();
    stderr.print("[{s}] {s} = {s}\n", .{ loc.asSlice(), src.asSlice(), msg.asSlice() }) catch unreachable;
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

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

var roc_main_path: []const u8 = undefined;
var project_dir: std.fs.Dir = undefined;
var site_paths = std.ArrayList([]const u8).init(allocator);

pub fn main() void {
    if (run()) {
        const stdout = std.io.getStdOut().writer();
        stdout.print("Bye!\n", .{}) catch unreachable;
    } else |err| {
        failCrudely(err);
    }
}

fn run() !void {
    var args = std.process.args();
    roc_main_path = args.next() orelse return error.EmptyArgv;
    const project_path = std.fs.path.dirname(roc_main_path) orelse return error.NoProjectPath;
    project_dir = std.fs.cwd().openDir(project_path, .{}) catch |err| {
        try failPrettily("Cannot access directory containing {s}: '{}'\n", .{ roc_main_path, err });
    };
    defer project_dir.close();

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

    try generateSite("output");
}

const RocPages = extern struct {
    payload: RocPagesPayload,
    tag: RocPagesTag,
};
const RocPagesPayload = extern union {
    filesIn: RocStr,
    files: RocList,
};
const RocPagesTag = enum(u8) {
    RocFiles = 0,
    RocFilesIn = 1,
};

export fn roc_fx_copy(pages: *RocPages) callconv(.C) RocResult(void, void) {
    if (copy(pages)) {
        return .{ .payload = .{ .ok = void{} }, .tag = .RocOk };
    } else |err| {
        failCrudely(err);
    }
}

fn copy(pages: *RocPages) !void {
    switch (pages.tag) {
        .RocFilesIn => {
            const dir_path = pages.payload.filesIn.asSlice();
            try processFilesIn(dropLeadingSlash(dir_path));
        },
        .RocFiles => {
            const paths_len = pages.payload.files.len();
            if (paths_len == 0) {
                return;
            }

            const elements = pages.payload.files.elements(RocStr) orelse return error.RocListUnexpectedlyEmpty;
            for (elements, 0..paths_len) |roc_str, _| {
                var path: []const u8 = try allocator.dupe(u8, roc_str.asSlice());
                path = dropLeadingSlash(path);
                try checkFileExists(path);
                try site_paths.append(path);
            }
        },
    }
}

fn processFilesIn(dir_path: []const u8) !void {
    const source_dir = project_dir.openDir(dir_path, .{ .iterate = true }) catch |err| {
        try failPrettily("Can't read directory '{s}': {}\n", .{ dir_path, err });
    };
    var dir_iter = source_dir.iterate();
    while (dir_iter.next()) |opt_entry| {
        if (opt_entry) |entry| {
            if (entry.kind != .file) {
                continue;
            }
            const segments = &[_][]const u8{ dir_path, entry.name };
            const rel_path = try std.fs.path.join(allocator, segments);
            try site_paths.append(rel_path);
        } else {
            break;
        }
    } else |err| {
        return err;
    }
}

test "processFilesIn: directory with files" {
    project_dir = std.testing.tmpDir(.{}).dir;
    try project_dir.makeDir("project");

    try project_dir.writeFile(.{ .sub_path = "project/file.1", .data = &[_]u8{} });
    try project_dir.writeFile(.{ .sub_path = "project/file.2", .data = &[_]u8{} });
    try project_dir.makeDir("project/dir"); // directory should not get added.

    try processFilesIn("project");

    try std.testing.expectEqual(2, site_paths.items.len);
    try std.testing.expectEqualStrings("project/file.1", site_paths.items[0]);
    try std.testing.expectEqualStrings("project/file.2", site_paths.items[1]);
}

test "processFilesIn: non-existing directory" {
    project_dir = std.testing.tmpDir(.{}).dir;
    try std.testing.expectError(error.PrettyError, processFilesIn("made-up"));
}

// For use in situations where we want to show a pretty helpful error.
// 'pretty' is relative, much work to do here to really live up to that.
fn failPrettily(comptime format: []const u8, args: anytype) !noreturn {
    const stderr = std.io.getStdErr().writer();
    try stderr.print(format, args);
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

fn checkFileExists(path: []const u8) !void {
    const stat = project_dir.statFile(path) catch |err| {
        try failPrettily("Can't read file '{s}': {}\n", .{ path, err });
    };
    if (stat.kind != .file) {
        try failPrettily("'{s}' is not a file\n", .{path});
    }
}

test "checkFileExists" {
    const dir = std.testing.tmpDir(.{});
    project_dir = dir.parent_dir;
    try dir.dir.writeFile(.{ .sub_path = "file", .data = &[_]u8{} });
    const file_path_segments = &[_][]const u8{ &dir.sub_path, "file" };
    const file_path = try std.fs.path.join(std.testing.allocator, file_path_segments);
    defer std.testing.allocator.free(file_path);

    try checkFileExists(file_path);
    try std.testing.expectError(error.PrettyError, checkFileExists("made/up/path"));
    try std.testing.expectError(error.PrettyError, checkFileExists(&dir.sub_path));
}

fn generateSite(output_dir_path: []const u8) !void {
    // Clear output directory if it already exists.
    project_dir.deleteTree(output_dir_path) catch |err| {
        if (err != error.NotDir) {
            return err;
        }
    };
    try project_dir.makeDir(output_dir_path);
    var output_dir = try project_dir.openDir(output_dir_path, .{});
    defer output_dir.close();

    const buffer = try allocator.alloc(u8, 1000);
    defer allocator.free(buffer);
    for (try site_paths.toOwnedSlice()) |file_path| {
        // I'd like to use the below, but get the following error when I do:
        //     hidden symbol `__dso_handle' isn't defined
        // try project_dir.copyFile(file_path, output_dir, file_path, .{});

        if (std.fs.path.dirname(file_path)) |parent_dir| {
            try output_dir.makePath(parent_dir);
        }
        var fifo = std.fifo.LinearFifo(u8, .Slice).init(buffer);
        defer fifo.deinit();
        const from_file = try project_dir.openFile(file_path, .{});
        defer from_file.close();
        const to_file = try output_dir.createFile(file_path, .{ .truncate = true, .exclusive = true });
        defer to_file.close();
        try fifo.pump(from_file.reader(), to_file.writer());
    }
}
