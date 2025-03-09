const std = @import("std");
const Str = @import("str.zig").Str;

// This MacOS watcher implementation uses the FSEvents API. The alternative
// would be using the kqueue API, which is also offered by BSD. kqueue requires
// putting watchers on individual files though, while FSEvents can watch a
// directory tree recursively and is reportedly more efficient.
//
// In order to be able to cross-compile this module we do not link it against
// the relevant MacOS library directly, but instead use dlopen to dynamically
// load coreservices at runtime. The downside of this approach is that we get
// no compile-time feedback on our integration. Ironically the best
// documentation I've found for integrating this API is the below Rust crate,
// which integrates with it too and shows specifically what types are exchanged.
// https://docs.rs/fsevent-sys/4.1.0/fsevent_sys/core_foundation/index.html

pub const Watcher = struct {
    const Self = @This();

    gpa: std.mem.Allocator,
    root_path: []const u8,
    watched_dir_paths: std.StringHashMapUnmanaged(Str),
    changed_paths: std.fifo.LinearFifo(PathChange, .Dynamic),
    changed_paths_mutex: std.Thread.Mutex,
    changed_paths_semaphore: std.Thread.Semaphore,
    buf: [std.fs.max_path_bytes]u8,
    handle: *anyopaque,
    stream: *anyopaque,
    FSEventStreamStop: *FSEventStreamStopType,
    FSEventStreamRelease: *FSEventStreamReleaseType,

    pub fn init(
        gpa: std.mem.Allocator,
        root_path_: []const u8,
    ) !*Self {
        const self = try gpa.create(Self);
        var root_path = root_path_;
        if (std.mem.endsWith(u8, root_path, "/")) {
            root_path = root_path[0 .. root_path.len - 1];
        }
        self.* = Self{
            .gpa = gpa,
            .root_path = try gpa.dupe(u8, root_path),
            .watched_dir_paths = std.StringHashMapUnmanaged(Str){},
            .changed_paths = std.fifo.LinearFifo(PathChange, .Dynamic).init(gpa),
            .changed_paths_mutex = std.Thread.Mutex{},
            .changed_paths_semaphore = std.Thread.Semaphore{},
            .buf = undefined,
            .handle = undefined,
            .stream = undefined,
            .FSEventStreamStop = undefined,
            .FSEventStreamRelease = undefined,
        };

        self.handle = try with_dlerror(
            std.c.dlopen(
                "/System/Library/Frameworks/CoreServices.framework/CoreServices",
                std.c.RTLD.LAZY,
            ),
            error.WatchFailedDlopenCoreServices,
        );
        errdefer std.debug.assert(0 == std.c.dlclose(self.handle));

        const FSEventStreamCreate: *FSEventStreamCreateType = @alignCast(@ptrCast(try with_dlerror(
            std.c.dlsym(self.handle, "FSEventStreamCreate"),
            error.WatchFailedLoadFSEventStreamCreate,
        )));

        const CFArrayCreate: *CFArrayCreateType = @alignCast(@ptrCast(try with_dlerror(
            std.c.dlsym(self.handle, "CFArrayCreate"),
            error.WatchFailedLoadCFArrayCreate,
        )));

        const CFStringCreateWithCString: *CFStringCreateWithCStringType = @alignCast(@ptrCast(try with_dlerror(
            std.c.dlsym(self.handle, "CFStringCreateWithCString"),
            error.WatchFailedLoadCFStringCreateWithCString,
        )));

        const FSEventStreamSetDispatchQueue: *FSEventStreamSetDispatchQueueType = @alignCast(@ptrCast(try with_dlerror(
            std.c.dlsym(self.handle, "FSEventStreamSetDispatchQueue"),
            error.WatchFailedLoadFSEventStreamSetDispatchQueue,
        )));

        const FSEventStreamStart: *FSEventStreamStartType = @alignCast(@ptrCast(try with_dlerror(
            std.c.dlsym(self.handle, "FSEventStreamStart"),
            error.WatchFailedLoadFSEventStreamStart,
        )));

        self.FSEventStreamRelease = @alignCast(@ptrCast(try with_dlerror(
            std.c.dlsym(self.handle, "FSEventStreamRelease"),
            error.WatchFailedLoadFSEventStreamRelease,
        )));

        self.FSEventStreamStop = @alignCast(@ptrCast(try with_dlerror(
            std.c.dlsym(self.handle, "FSEventStreamStop"),
            error.WatchFailedLoadFSEventStreamStop,
        )));

        const dispatch_queue_create: *dispatch_queue_create_type = @alignCast(@ptrCast(try with_dlerror(
            std.c.dlsym(self.handle, "dispatch_queue_create"),
            error.WatchFailedLoaddispatch_queue_create,
        )));

        var context = FSEventStreamContext{
            .version = 0,
            .info = self,
            .retain = null,
            .release = null,
            .copy_description = null,
        };

        // The constant representing UTF8. We use it to represent paths,
        // which is not actually correct, but I don't know what else to
        // pick given paths don't really have an encoding at all.
        // https://developer.apple.com/documentation/corefoundation/cfstringbuiltinencodings/utf8
        const utf8 = 134217984;

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        _ = try std.fmt.bufPrint(&buf, "{s}\x00", .{root_path});
        const root_path_cfstring = CFStringCreateWithCString(
            null,
            buf[0..root_path.len :0],
            utf8,
        );

        var paths = [_]*anyopaque{root_path_cfstring};
        const event_paths = CFArrayCreate(null, @ptrCast(&paths), 1, null);

        const flags =
            kFSEventStreamCreateFlagWatchRoot |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer;
        self.stream = FSEventStreamCreate(
            null,
            &handleEvent,
            &context,
            event_paths,
            kFSEventStreamEventIdSinceNow,
            0.01, // milliseconds
            flags,
        ) orelse return error.WatchFailedFSEventStreamCreate;

        const queue = dispatch_queue_create(null, null);

        FSEventStreamSetDispatchQueue(self.stream, queue);

        std.debug.assert(FSEventStreamStart(self.stream));

        return self;
    }

    fn handleEvent(
        stream_ref: *const anyopaque,
        client_callback_info: *anyopaque,
        num_events: isize,
        event_paths: [*][*:0]const u8,
        event_flags: [*]u32,
        event_ids: [*]u64,
    ) callconv(.C) void {
        _ = stream_ref;
        _ = event_flags;
        _ = event_ids;
        var self: *Self = @alignCast(@ptrCast(client_callback_info));
        self.changed_paths_mutex.lock();
        defer self.changed_paths_mutex.unlock();
        for (event_paths[0..@intCast(num_events)]) |event_path| {
            var path: []const u8 = std.mem.span(event_path);
            if (std.mem.endsWith(u8, path, "/")) {
                path = path[0 .. path.len - 1];
            }
            self.handlePathChange(path) catch |err| {
                std.debug.print("Error in Watcher.handleEvent: {s}\n", .{@errorName(err)});
                @panic("Error in Watcher.handleEvent");
            };
        }
    }

    fn handlePathChange(self: *Self, full_path: []const u8) !void {
        std.debug.assert(std.mem.startsWith(u8, full_path, self.root_path));
        const path = if (self.root_path.len == full_path.len)
            ""
        else
            // Take off the root path and the directory separator directly after.
            full_path[self.root_path.len + 1 ..];
        const dir_path = std.fs.path.dirname(path) orelse "";
        const dir = self.watched_dir_paths.get(dir_path) orelse return;
        const file_name = std.fs.path.basename(path);
        const change = .{
            .dir = dir,
            .file_name = try self.gpa.dupe(u8, file_name),
        };
        try self.changed_paths.writeItem(change);
        self.changed_paths_semaphore.post();
    }

    pub fn deinit(self: *Self) void {
        // Stop producing new events
        self.FSEventStreamStop(self.stream);
        self.FSEventStreamRelease(self.stream);

        // Wait until processing for the last event finishes.
        self.changed_paths_mutex.lock();
        self.changed_paths_mutex.unlock();

        std.debug.assert(0 == std.c.dlclose(self.handle));
        self.gpa.free(self.root_path);
        var keys = self.watched_dir_paths.keyIterator();
        while (keys.next()) |key| {
            self.gpa.free(key.*);
        }
        self.watched_dir_paths.deinit(self.gpa);

        while (self.changed_paths.readItem()) |change| self.gpa.free(change.file_name);
        self.changed_paths.deinit();

        self.gpa.destroy(self);
    }

    pub fn watchDir(self: *Self, dir: Str) !void {
        const path = dir.bytes();
        self.changed_paths_mutex.lock();
        defer self.changed_paths_mutex.unlock();
        const get_or_put = try self.watched_dir_paths.getOrPut(self.gpa, path);
        if (get_or_put.found_existing) return;
        get_or_put.key_ptr.* = try self.gpa.dupe(u8, path);
        get_or_put.value_ptr.* = dir;
    }

    pub fn nextWait(self: *Self, max_wait_ms: i32) !?Change {
        self.changed_paths_semaphore.timedWait(@as(u64, @intCast(max_wait_ms)) * 1000_000) catch {
            return null;
        };
        self.changed_paths_mutex.lock();
        defer self.changed_paths_mutex.unlock();
        const change = self.changed_paths.readItem() orelse return error.WatchMissingChange;
        @memcpy(self.buf[0..change.file_name.len], change.file_name);
        defer self.gpa.free(change.file_name);
        return .{ .path_changed = .{
            .dir = change.dir,
            .file_name = self.buf[0..change.file_name.len],
        } };
    }

    pub const Change = union(enum) {
        changes_missed: void,
        path_changed: PathChange,
    };

    pub const PathChange = struct {
        dir: Str,
        file_name: []const u8,
    };
};

fn with_dlerror(res: ?*anyopaque, err: anyerror) !*anyopaque {
    if (res) |success| {
        return success;
    } else if (dlerror()) |dlerr| {
        std.debug.print("Failed {s}: {s}\n", .{ @errorName(err), dlerr });
        return err;
    } else {
        std.debug.print("Failed {s} with no dlerror response", .{@errorName(err)});
        return err;
    }
}

fn dlerror() ?[]const u8 {
    return if (std.c.dlerror()) |err| std.mem.span(err) else null;
}

const FSEventStreamContext = extern struct {
    version: isize,
    info: *anyopaque,
    retain: ?*anyopaque,
    release: ?*anyopaque,
    copy_description: ?*anyopaque,
};

const FSEventStreamCreateType: type = fn (
    allocator: ?*anyopaque,
    callback: *const fn (
        stream_ref: *const anyopaque,
        client_callback_info: *anyopaque,
        num_events: isize,
        event_paths: [*][*:0]const u8,
        event_flags: [*]u32,
        event_ids: [*]u64,
    ) callconv(.C) void,
    context: *FSEventStreamContext,
    paths_to_watch: *anyopaque,
    since_when: u64,
    latency: f64,
    flags: u32,
) ?*anyopaque;

const CFArrayCreateType: type = fn (
    allocator: ?*anyopaque,
    values: [*]*anyopaque,
    num_values: isize,
    callbacks: ?*anyopaque,
) *anyopaque;

const CFStringCreateWithCStringType: type = fn (
    allocator: ?*anyopaque,
    c_str: [*:0]const u8,
    encoding: u32,
) *anyopaque;

const FSEventStreamSetDispatchQueueType: type = fn (
    stream_ref: *anyopaque,
    dispatch_queue: *anyopaque,
) void;

const FSEventStreamStartType: type = fn (
    stream_ref: *anyopaque,
) bool;

const FSEventStreamStopType: type = fn (
    stream_ref: *anyopaque,
) void;

const FSEventStreamReleaseType: type = fn (
    stream_ref: *anyopaque,
) void;

// https://developer.apple.com/documentation/dispatch/1453030-dispatch_queue_create
const dispatch_queue_create_type: type = fn (
    label: ?*anyopaque,
    dispatch_queue_attr_t: ?*anyopaque,
) *anyopaque;

// I get an error when I try to `dlsym` a constant, not sure why.
// Constant values are documented in the Objective-C docs for them though:
// https://developer.apple.com/documentation/coreservices?language=objc
const kFSEventStreamCreateFlagNoDefer: u32 = 0x00000002;
const kFSEventStreamCreateFlagWatchRoot: u32 = 0x00000004;
const kFSEventStreamCreateFlagFileEvents: u32 = 0x00000010;
const kFSEventStreamEventIdSinceNow: u64 = 0xFFFFFFFFFFFFFFFF;
