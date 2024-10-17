const std = @import("std");
const builtin = @import("builtin");
const RocStr = @import("roc/str.zig").RocStr;
const RocList = @import("roc/list.zig").RocList;
const RocResult = @import("roc/result.zig").RocResult;
const utils = @import("roc/utils.zig");
const testing = std.testing;
const expectEqual = testing.expectEqual;
const expect = testing.expect;

const Align = 2 * @alignOf(usize);
extern fn malloc(size: usize) callconv(.C) ?*align(Align) anyopaque;
extern fn realloc(c_ptr: [*]align(Align) u8, size: usize) callconv(.C) ?*anyopaque;
extern fn free(c_ptr: [*]align(Align) u8) callconv(.C) void;
extern fn memcpy(dst: [*]u8, src: [*]u8, size: usize) callconv(.C) void;
extern fn memset(dst: [*]u8, value: i32, size: usize) callconv(.C) void;

export fn roc_alloc(size: usize, alignment: u32) callconv(.C) *anyopaque {
    _ = alignment;
    return malloc(size).?;
}

export fn roc_realloc(old_ptr: *anyopaque, new_size: usize, old_size: usize, alignment: u32) callconv(.C) *anyopaque {
    _ = old_size;
    _ = alignment;
    return realloc(@as([*]align(Align) u8, @alignCast(@ptrCast(old_ptr))), new_size).?;
}

export fn roc_dealloc(c_ptr: *anyopaque, alignment: u32) callconv(.C) void {
    _ = alignment;
    free(@as([*]align(Align) u8, @alignCast(@ptrCast(c_ptr))));
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
    return memset(dst, value, size);
}

extern fn kill(pid: c_int, sig: c_int) c_int;
extern fn shm_open(name: *const i8, oflag: c_int, mode: c_uint) c_int;
extern fn mmap(addr: ?*anyopaque, length: c_uint, prot: c_int, flags: c_int, fd: c_int, offset: c_uint) *anyopaque;
extern fn getppid() c_int;

fn roc_getppid() callconv(.C) c_int {
    return getppid();
}

fn roc_getppid_windows_stub() callconv(.C) c_int {
    return 0;
}

fn roc_shm_open(name: *const i8, oflag: c_int, mode: c_uint) callconv(.C) c_int {
    return shm_open(name, oflag, mode);
}
fn roc_mmap(addr: ?*anyopaque, length: c_uint, prot: c_int, flags: c_int, fd: c_int, offset: c_uint) callconv(.C) *anyopaque {
    return mmap(addr, length, prot, flags, fd, offset);
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

const Unit = extern struct {};

pub fn main() void {
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    var timer = std.time.Timer.start() catch unreachable;

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

    const nanos = timer.read();
    const seconds = (@as(f64, @floatFromInt(nanos)) / 1_000_000_000.0);

    switch (out.tag) {
        .RocOk => {
            stdout.print("Runtime: {d:.3}ms\n", .{seconds * 1000}) catch unreachable;
        },
        .RocErr => {
            stderr.print("Exited with code {d}, in {d:.3}ms\n", .{ out.payload.err, seconds * 1000 }) catch unreachable;
        },
    }
}

var stored_pages: ?*anyopaque = null;

export fn roc_fx_writePages(pages: *anyopaque) callconv(.C) RocResult(void, void) {
    // TODO: fix pages refs leaking.
    utils.increfDataPtrC(@ptrCast(pages), 1);
    stored_pages = pages;
    return .{ .payload = .{ .ok = void{} }, .tag = .RocOk };
}

export fn roc_fx_readPages() callconv(.C) RocResult(*anyopaque, void) {
    if (stored_pages) |stored| {
        return .{ .payload = .{ .ok = stored }, .tag = .RocOk };
    } else {
        return .{ .payload = .{ .err = void{} }, .tag = .RocErr };
    }
}
