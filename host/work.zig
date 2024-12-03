// A work queue. Primarily intended to organize work resulting from file watch
// events, but we might make it thread-safe at some point to enable
// parallization.

const std = @import("std");
const Path = @import("path.zig").Path;

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
        scan_dir: Path,
        // Scan a file, to:
        // - Add it, if we're not tracking it yet and it's un-ignored
        // - Remove it, if we area tracking it and now it's deleted / ignored
        // - Regenerate it, if we're tracking it and it was changed
        // - Add it, if we're not tracking it yet and it's un-ignored
        //   This requires a Page stub to have been written first!
        scan_file: Path,
        generate_file: Path,
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
                .scan_dir => std.math.order(a.scan_dir.index(), b.scan_dir.index()),
                .scan_file => std.math.order(a.scan_file.index(), b.scan_file.index()),
                .generate_file => std.math.order(a.generate_file.index(), b.generate_file.index()),
            },
        };
    }
};
