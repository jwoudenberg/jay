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
var project_path: []const u8 = undefined;
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
    // Get the path of the
    var args = std.process.args();
    roc_main_path = args.next() orelse return error.EmptyArgv;
    project_path = std.fs.path.dirname(roc_main_path) orelse return error.NoProjectPath;

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

fn copy(pages: *RocPages) error{ OutOfMemory, RocListUnexpectedlyEmpty }!void {
    switch (pages.tag) {
        .RocFilesIn => {
            const path = try allocator.dupe(u8, pages.payload.filesIn.asSlice());
            try site_paths.append(path);
        },
        .RocFiles => {
            const paths_len = pages.payload.files.len();
            if (paths_len > 0) {
                const elements = pages.payload.files.elements(RocStr) orelse return error.RocListUnexpectedlyEmpty;
                for (elements, 0..paths_len) |roc_str, _| {
                    const path = try allocator.dupe(u8, roc_str.asSlice());
                    try site_paths.append(path);
                }
            }
        },
    }
}
