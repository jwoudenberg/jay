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
    const stderr = std.io.getStdErr().writer();
    stderr.print("\n\nRoc crashed with the following error;\nMSG:{s}\nTAG:{d}\n\nShutting down\n", .{ msg.asSlice(), tag_id }) catch unreachable;
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
        const stderr = std.io.getStdErr().writer();
        stderr.print("Error {}\n", .{err}) catch unreachable;
        std.process.exit(1);
    }
}

fn run() error{ OutOfMemory, EmptyArgv, NoProjectPath }!void {
    var args = std.process.args();
    roc_main_path = args.next() orelse return error.EmptyArgv;
    const project_path = std.fs.path.dirname(roc_main_path) orelse return error.NoProjectPath;
    project_dir = std.fs.cwd().openDir(project_path, .{}) catch |err| {
        const stderr = std.io.getStdErr().writer();
        stderr.print("Cannot access directory containing {s}: '{}'\n", .{ roc_main_path, err }) catch unreachable;
        std.process.exit(1);
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

    for (try site_paths.toOwnedSlice()) |path| {
        std.debug.print("path: {s}\n", .{path});
    }
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
        const stderr = std.io.getStdErr().writer();
        stderr.print("Error {}\n", .{err}) catch unreachable;
        std.process.exit(1);
    }
}

const CopyError = error{ OutOfMemory, RocListUnexpectedlyEmpty, AccessDenied, SystemResources, Unexpected, InvalidUtf8 };
fn copy(pages: *RocPages) CopyError!void {
    switch (pages.tag) {
        .RocFilesIn => {
            const dir_path = pages.payload.filesIn.asSlice();
            try process_files_in(drop_leading_slash(dir_path));
        },
        .RocFiles => {
            const paths_len = pages.payload.files.len();
            if (paths_len == 0) {
                return;
            }

            const elements = pages.payload.files.elements(RocStr) orelse return error.RocListUnexpectedlyEmpty;
            for (elements, 0..paths_len) |roc_str, _| {
                var path: []const u8 = try allocator.dupe(u8, roc_str.asSlice());
                path = drop_leading_slash(path);
                checkPathExists(path);
                try site_paths.append(path);
            }
        },
    }
}

fn process_files_in(dir_path: []const u8) !void {
    const source_dir = project_dir.openDir(dir_path, .{ .iterate = true }) catch |err| {
        const stderr = std.io.getStdErr().writer();
        stderr.print("Can't read directory '{s}': {}\n", .{ dir_path, err }) catch unreachable;
        std.process.exit(1);
    };
    var dir_iter = source_dir.iterate();
    while (dir_iter.next()) |opt_entry| {
        if (opt_entry) |entry| {
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

fn drop_leading_slash(path: []const u8) []const u8 {
    if (path.len == 0) {
        return path;
    } else if (std.fs.path.isSep(path[0])) {
        return path[1..];
    } else {
        return path;
    }
}

fn checkPathExists(path: []const u8) void {
    project_dir.access(path, .{}) catch |err| {
        const stderr = std.io.getStdErr().writer();
        stderr.print("Can't read file '{s}': {}\n", .{ path, err }) catch unreachable;
        std.process.exit(1);
    };
}
