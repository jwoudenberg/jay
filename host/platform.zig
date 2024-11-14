// Functions and types for interacting with the platform code.

const builtin = @import("builtin");
const fail = @import("fail.zig");
const std = @import("std");
const RocStr = @import("roc/str.zig").RocStr;
const RocList = @import("roc/list.zig").RocList;

pub extern fn roc__mainForHost_1_exposed_generic(*RocList, *const void) callconv(.C) void;
pub extern fn roc__getMetadataLengthForHost_1_exposed_generic(*u64, *const RocList) callconv(.C) void;
pub extern fn roc__runPipelineForHost_1_exposed_generic(*RocList, *const Page) callconv(.C) void;

pub const Rule = extern struct {
    patterns: RocList,
    replaceTags: RocList,
    processing: Processing,
};

pub const Page = extern struct {
    meta: RocList,
    path: RocStr,
    tags: RocList,
    len: u32,
    ruleIndex: u32,
};

pub const Processing = enum(u8) {
    bootstrap = 0,
    ignore = 1,
    markdown = 2,
    none = 3,
    xml = 4,
};

pub const Tag = extern struct {
    attributes: RocList,
    index: u32,
    innerEnd: u32,
    innerStart: u32,
    outerEnd: u32,
    outerStart: u32,
};

pub const Slice = extern struct {
    payload: SlicePayload,
    tag: SliceTag,
};

pub const SlicePayload = extern union {
    from_source: SourceLoc,
    roc_generated: RocList,
};

pub const SliceTag = enum(u8) {
    from_source = 0,
    roc_generated = 1,
};

const SourceLoc = extern struct {
    end: u32,
    start: u32,
};

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

// The platform code uses 'crash' to 'throw' an error to the host in certain
// situations. We can kind of get away with it because compile-time and
// runtime are essentially the same time for this program, and so runtime
// errors have fewer downsides then they might have in other platforms.
//
// To distinguish platform panics from user panics, we prefix platform panics
// with a ridiculous string that hopefully never will attempt to copy.
const panic_prefix = "@$%^&.jayerror*";
export fn roc_panic(roc_msg: *RocStr, tag_id: u32) callconv(.C) void {
    const msg = roc_msg.asSlice();
    if (!std.mem.startsWith(u8, msg, panic_prefix)) {
        fail.prettily(
            \\
            \\Roc crashed with the following error:
            \\MSG:{s}
            \\TAG:{d}
            \\
            \\Shutting down
            \\
        , .{ msg, tag_id }) catch {};
        std.process.exit(1);
    }

    const code = msg[panic_prefix.len];
    const details = msg[panic_prefix.len + 2 ..];
    switch (code) {
        '0' => {
            fail.prettily(
                \\I ran into an error attempting to decode the following metadata:
                \\
                \\{s}
                \\
            , .{details}) catch {};
            std.process.exit(1);
        },
        '1' => {
            fail.prettily(
                \\I ran into an error attempting to decode the following attributes:
                \\
                \\{s}
                \\
            , .{details}) catch {};
            std.process.exit(1);
        },
        else => {
            fail.prettily("Unknown panic error code: {d}", .{code}) catch {};
            std.process.exit(1);
        },
    }
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

pub fn RocListIterator(comptime T: type) type {
    return struct {
        const Self = @This();

        elements: ?[*]T,
        len: usize,
        index: usize,

        pub fn init(list: RocList) Self {
            return Self{
                .elements = list.elements(T),
                .len = list.len(),
                .index = 0,
            };
        }

        pub fn next(self: *Self) ?T {
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
