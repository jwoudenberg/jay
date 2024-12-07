// A work queue. Primarily intended to organize work resulting from file watch
// events, but we might make it thread-safe at some point to enable
// parallization.

const std = @import("std");
const Str = @import("str.zig").Str;

pub const WorkQueue = struct {
    // In the current (single-threaded) setup we use a priority queue to ensure
    // that we perform all the directory and file scans before we start
    // generating output files, because generating output files requires
    // knowledge of scanned files.
    //
    // In a potential future multi-threaded scenario the same prioritization
    // makes sense, but for a different reason: we'll want to run jobs that
    // might generate extra work such as directory scans first, to maximize
    // use of parallel threads.
    queue: std.PriorityQueue(Job, void, compare),

    pub fn init(allocator: std.mem.Allocator) WorkQueue {
        return WorkQueue{
            .queue = std.PriorityQueue(Job, void, compare).init(allocator, void{}),
        };
    }

    pub fn deinit(self: *WorkQueue) void {
        self.queue.deinit();
    }

    pub fn push(self: *WorkQueue, job: Job) !void {
        return self.queue.add(job);
    }

    pub fn pop(self: *WorkQueue) ?Job {
        const job = self.queue.removeOrNull();
        return job;
    }

    // Jobs are ordered from highest priority at the top to lowest at the
    // bottom.
    pub const Job = union(enum) {
        // Scan a directory, when:
        // - We scan the project for the first time
        // - A directory has been moved into the source file directory
        // - Our watcher lost the plot and we have to do a fresh scan
        // This will recursively start more of itself for subdirectories.
        scan_dir: Str,
        // Scan a file, to:
        // - Add it, if we're not tracking it yet and it's un-ignored
        // - Remove it, if we area tracking it and now it's deleted / ignored
        // - Regenerate it, if we're tracking it and it was changed
        // - Add it, if we're not tracking it yet and it's un-ignored
        //   This requires a Page stub to have been written first!
        scan_file: Str,
        generate_file: Str,
    };

    fn compare(context: void, a: Job, b: Job) std.math.Order {
        _ = context;
        const order = std.math.order(
            @intFromEnum(std.meta.activeTag(a)),
            @intFromEnum(std.meta.activeTag(b)),
        );
        return switch (order) {
            .lt, .gt => order,
            .eq => switch (a) {
                .scan_dir => std.ascii.orderIgnoreCase(a.scan_dir.bytes(), b.scan_dir.bytes()),
                .scan_file => std.ascii.orderIgnoreCase(a.scan_file.bytes(), b.scan_file.bytes()),
                .generate_file => std.ascii.orderIgnoreCase(a.generate_file.bytes(), b.generate_file.bytes()),
            },
        };
    }
};
