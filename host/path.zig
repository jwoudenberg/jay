// Helper for interning paths and giving each an index.

const std = @import("std");
const fail = @import("fail.zig");
const mime = @import("mime");
const glob = @import("glob.zig");
const native_endian = @import("builtin").target.cpu.arch.endian();

pub const Path = enum(usize) {
    _,

    pub fn bytes(self: Path) []const u8 {
        const ptr: [*]u8 = @ptrFromInt(@intFromEnum(self));
        const len = std.mem.readInt(usize, ptr[@sizeOf(usize) .. 2 * @sizeOf(usize)], native_endian);
        const start = 2 * @sizeOf(usize);
        return ptr[start .. start + len];
    }

    pub fn index(self: Path) usize {
        const ptr = @as([*]u8, @ptrFromInt(@intFromEnum(self)));
        return std.mem.readInt(usize, ptr[0..@sizeOf(usize)], native_endian);
    }

    pub const Registry = struct {
        gpa: std.mem.Allocator,
        arena_state: std.heap.ArenaAllocator,
        paths: std.StringHashMapUnmanaged(Path),
        mutex: std.Thread.Mutex,

        pub fn init(gpa: std.mem.Allocator) Registry {
            const arena_state = std.heap.ArenaAllocator.init(gpa);
            return Registry{
                .gpa = gpa,
                .arena_state = arena_state,
                .paths = std.StringHashMapUnmanaged(Path){},
                .mutex = std.Thread.Mutex{},
            };
        }

        pub fn deinit(self: *Registry) void {
            self.arena_state.deinit();
            self.paths.deinit(self.gpa);
        }

        pub fn get(self: *Registry, path: []const u8) ?Path {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.paths.get(path);
        }

        pub fn intern(self: *Registry, path: []const u8) !Path {
            self.mutex.lock();
            defer self.mutex.unlock();

            const get_or_put = try self.paths.getOrPut(self.gpa, path);
            if (get_or_put.found_existing) {
                return get_or_put.value_ptr.*;
            }

            const next_index = self.paths.count() - 1;
            var buffer = try self.arena_state.allocator().alignedAlloc(
                u8,
                @sizeOf(usize),
                2 * @sizeOf(usize) + path.len,
            );
            std.mem.writeInt(usize, buffer[0..@sizeOf(usize)], next_index, native_endian);
            std.mem.writeInt(usize, buffer[@sizeOf(usize) .. 2 * @sizeOf(usize)], path.len, native_endian);
            const interned_path = buffer[2 * @sizeOf(usize) ..];
            @memcpy(interned_path, path);
            const wrapped_path: Path = @enumFromInt(@intFromPtr(&buffer[0]));
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
    try std.testing.expectEqual(0, path1.index());
    try std.testing.expectEqualStrings("/other/file.txt", path2.bytes());
    try std.testing.expectEqual(1, path2.index());
    try std.testing.expectEqualStrings("/other/file.txt", path3.bytes());
    try std.testing.expectEqual(1, path2.index());

    try std.testing.expect(path2 == path3);
    try std.testing.expect(path1 != path2);
    try std.testing.expect(path1 != path3);
}
