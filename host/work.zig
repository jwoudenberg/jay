// A work queue. Primarily intended to organize work resulting from file watch
// events, but we might make it thread-safe at some point to enable
// parallization.

const std = @import("std");
const Site = @import("site.zig").Site;
const Watcher = @import("watch.zig").Watcher;

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
        // Scan a directory, when:
        // - We scan the project for the first time
        // - A directory has been moved into the source file directory
        // - Our watcher lost the plot and we have to do a fresh scan
        // This will recursively start more of itself for subdirectories.
        scan_dir: Watcher.DirIndex,
        // Scan a file, to:
        // - Add it, if we're not tracking it yet and it's un-ignored
        // - Remove it, if we area tracking it and now it's deleted / ignored
        // - Regenerate it, if we're tracking it and it was changed
        // - Add it, if we're not tracking it yet and it's un-ignored
        //   This requires a Page stub to have been written first!
        scan_file: Site.PageIndex,
        generate_page: Site.PageIndex,
    };
};
