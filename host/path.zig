// Helper for interning paths and giving each an index.

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
// The index is used to store the page index for file paths. For other types
// of strings it is currently unused.
pub const Path = enum(usize) {
    _,

    pub const init_index = std.math.maxInt(usize);

    pub fn bytes(self: Path) []const u8 {
        const ptr: [*]u8 = @ptrFromInt(@intFromEnum(self));
        const len: *usize = @ptrFromInt(@intFromEnum(self));
        return (ptr + @sizeOf(usize))[0..len.*];
    }

    pub fn index(self: Path) usize {
        const ptr: *usize = @ptrFromInt(@intFromEnum(self) - @sizeOf(usize));
        return @atomicLoad(usize, ptr, .monotonic);
    }

    pub fn replaceIndex(self: Path, new: usize) usize {
        const ptr: *usize = @ptrFromInt(@intFromEnum(self) - @sizeOf(usize));
        return @atomicRmw(usize, ptr, .Xchg, new, .monotonic);
    }

    pub const Registry = struct {
        arena_state: std.heap.ArenaAllocator,
        paths: std.StringHashMapUnmanaged(Path),
        mutex: std.Thread.Mutex,

        pub fn init(gpa: std.mem.Allocator) Registry {
            const arena_state = std.heap.ArenaAllocator.init(gpa);
            return Registry{
                .arena_state = arena_state,
                .paths = std.StringHashMapUnmanaged(Path){},
                .mutex = std.Thread.Mutex{},
            };
        }

        pub fn deinit(self: *Registry) void {
            self.paths.deinit(self.arena_state.child_allocator);
            self.arena_state.deinit();
        }

        pub fn get(self: *Registry, path: []const u8) ?Path {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.paths.get(path);
        }

        pub fn intern(self: *Registry, path: []const u8) !Path {
            self.mutex.lock();
            defer self.mutex.unlock();

            const get_or_put = try self.paths.getOrPut(self.arena_state.child_allocator, path);
            if (get_or_put.found_existing) {
                return get_or_put.value_ptr.*;
            }

            var buffer = try self.arena_state.allocator().alignedAlloc(
                u8,
                @sizeOf(usize),
                2 * @sizeOf(usize) + path.len,
            );
            std.mem.writeInt(usize, buffer[0..@sizeOf(usize)], init_index, native_endian);
            std.mem.writeInt(usize, buffer[@sizeOf(usize) .. 2 * @sizeOf(usize)], path.len, native_endian);
            const interned_path = buffer[2 * @sizeOf(usize) ..];
            @memcpy(interned_path, path);
            const wrapped_path: Path = @enumFromInt(@intFromPtr(&buffer[@sizeOf(usize)]));
            get_or_put.key_ptr.* = interned_path;
            get_or_put.value_ptr.* = wrapped_path;
            return wrapped_path;
        }
    };
};

test "Path.Registry" {
    var paths = Path.Registry.init(std.testing.allocator);
    defer paths.deinit();

    const path1 = try paths.intern("/some/path/file.txt");
    const path2 = try paths.intern("/other/file.txt");
    const path3 = try paths.intern("/other/file.txt");

    try std.testing.expectEqualStrings("/some/path/file.txt", path1.bytes());
    try std.testing.expectEqualStrings("/other/file.txt", path2.bytes());
    try std.testing.expectEqualStrings("/other/file.txt", path3.bytes());

    try std.testing.expectEqual(Path.init_index, path1.replaceIndex(4));
    try std.testing.expectEqual(4, path1.index());
    try std.testing.expectEqual(4, path1.replaceIndex(5));
    try std.testing.expectEqual(5, path1.index());
    try std.testing.expectEqual(Path.init_index, path2.index());

    try std.testing.expect(path2 == path3);
    try std.testing.expect(path1 != path2);
    try std.testing.expect(path1 != path3);
}
