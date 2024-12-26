// Helper for interning strings.

const std = @import("std");
const fail = @import("fail.zig");
const mime = @import("mime");
const glob = @import("glob.zig");
const native_endian = @import("builtin").target.cpu.arch.endian();

// Pointer to an interned slice of bytes.
//
//     | index | len   | slice bytes ..
//     | usize | usize | ..
//             ^
//           pointer
//
// The index is used to store the page index for file strs. For other types
// of strings it is currently unused.
pub const Str = enum(usize) {
    _,

    pub const init_index = std.math.maxInt(usize);

    pub fn len(self: Str) usize {
        const res: *usize = @ptrFromInt(@intFromEnum(self));
        return res.*;
    }

    pub fn bytes(self: Str) []const u8 {
        const ptr: [*]u8 = @ptrFromInt(@intFromEnum(self));
        return (ptr + @sizeOf(usize))[0..self.len()];
    }

    pub fn index(self: Str) usize {
        const ptr: *usize = @ptrFromInt(@intFromEnum(self) - @sizeOf(usize));
        return @atomicLoad(usize, ptr, .monotonic);
    }

    pub fn replaceIndex(self: Str, new: usize) usize {
        const ptr: *usize = @ptrFromInt(@intFromEnum(self) - @sizeOf(usize));
        return @atomicRmw(usize, ptr, .Xchg, new, .monotonic);
    }

    pub const Registry = struct {
        state: *State,

        const State = struct {
            arena_state: std.heap.ArenaAllocator,
            strs: std.StringHashMapUnmanaged(Str),
            mutex: std.Thread.Mutex,
        };

        pub fn init(gpa: std.mem.Allocator) !Registry {
            const state = try gpa.create(State);
            state.* = .{
                .arena_state = std.heap.ArenaAllocator.init(gpa),
                .strs = .{},
                .mutex = .{},
            };
            return Registry{ .state = state };
        }

        pub fn deinit(self: Registry) void {
            var state = self.state;
            var child_allocator = state.arena_state.child_allocator;
            state.strs.deinit(child_allocator);
            state.arena_state.deinit();
            child_allocator.destroy(state);
        }

        pub fn get(self: Registry, slice: []const u8) ?Str {
            var state = self.state;
            state.mutex.lock();
            defer state.mutex.unlock();
            return state.strs.get(slice);
        }

        pub fn intern(self: Registry, slice: []const u8) !Str {
            var state = self.state;
            state.mutex.lock();
            defer state.mutex.unlock();

            const get_or_put = try state.strs.getOrPut(state.arena_state.child_allocator, slice);
            if (get_or_put.found_existing) {
                return get_or_put.value_ptr.*;
            }

            var buffer = try state.arena_state.allocator().alignedAlloc(
                u8,
                @sizeOf(usize),
                2 * @sizeOf(usize) + slice.len,
            );
            std.mem.writeInt(usize, buffer[0..@sizeOf(usize)], init_index, native_endian);
            std.mem.writeInt(usize, buffer[@sizeOf(usize) .. 2 * @sizeOf(usize)], slice.len, native_endian);
            const interned_str = buffer[2 * @sizeOf(usize) ..];
            @memcpy(interned_str, slice);
            const wrapped_str: Str = @enumFromInt(@intFromPtr(&buffer[@sizeOf(usize)]));
            get_or_put.key_ptr.* = interned_str;
            get_or_put.value_ptr.* = wrapped_str;
            return wrapped_str;
        }
    };
};

test "Str.Registry" {
    var strs = try Str.Registry.init(std.testing.allocator);
    defer strs.deinit();

    const str1 = try strs.intern("/some/str/file.txt");
    const str2 = try strs.intern("/other/file.txt");
    const str3 = try strs.intern("/other/file.txt");

    try std.testing.expectEqualStrings("/some/str/file.txt", str1.bytes());
    try std.testing.expectEqual(18, str1.len());
    try std.testing.expectEqualStrings("/other/file.txt", str2.bytes());
    try std.testing.expectEqual(15, str2.len());
    try std.testing.expectEqualStrings("/other/file.txt", str3.bytes());
    try std.testing.expectEqual(15, str3.len());

    try std.testing.expectEqual(Str.init_index, str1.replaceIndex(4));
    try std.testing.expectEqual(4, str1.index());
    try std.testing.expectEqual(4, str1.replaceIndex(5));
    try std.testing.expectEqual(5, str1.index());
    try std.testing.expectEqual(Str.init_index, str2.index());

    try std.testing.expect(str2 == str3);
    try std.testing.expect(str1 != str2);
    try std.testing.expect(str1 != str3);
}
