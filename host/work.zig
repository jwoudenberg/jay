// A work queue. Primarily intended to organize work resulting from file watch
// events, but we might make it thread-safe at some point to enable
// parallization.

const std = @import("std");
const Site = @import("site.zig").Site;

pub const WorkQueue = struct {
    allocator: std.mem.Allocator,
    queue: std.SegmentedList(Job, 0),

    pub fn init(allocator: std.mem.Allocator) WorkQueue {
        return WorkQueue{
            .allocator = allocator,
            .queue = std.SegmentedList(Job, 0){},
        };
    }

    pub fn deinit(self: *WorkQueue) void {
        self.queue.deinit(self.allocator);
    }

    pub fn push(self: *WorkQueue, job: Job) !void {
        return self.queue.append(self.allocator, job);
    }

    pub fn pop(self: *WorkQueue) ?Job {
        return self.queue.pop();
    }

    pub const Job = union(enum) {
        scan_dir: Site.DirIndex,
        scan_file: Site.PageIndex,
        generate_page: Site.PageIndex,
    };
};
