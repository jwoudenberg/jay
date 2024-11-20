const std = @import("std");
const Site = @import("site.zig").Site;
const WorkQueue = @import("work.zig").WorkQueue;
const fanotify = @import("fanotify.zig");

pub const Watcher = struct {
    pub fn init(allocator: std.mem.Allocator) !Watcher {
        _ = allocator;
        unreachable;
    }

    pub fn deinit(self: *Watcher) void {
        _ = self;
    }

    pub fn watchDir(self: *Watcher, path: []const u8) !DirIndex {
        _ = self;
        _ = path;
        unreachable;
    }

    pub fn next(self: *Watcher) !Change {
        _ = self;
        unreachable;
    }

    pub fn dirPath(self: *Watcher, index: DirIndex) []const u8 {
        _ = self;
        _ = index;
        unreachable;
    }

    pub const DirIndex = enum(i32) {};

    const Change = struct {
        dir: DirIndex,
        filename: []const u8,
    };
};
