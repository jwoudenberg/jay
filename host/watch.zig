const std = @import("std");
const Site = @import("site.zig").Site;
const WorkQueue = @import("work.zig").WorkQueue;
const Path = @import("path.zig").Path;
const fanotify = @import("fanotify.zig");

pub const Watcher = struct {
    paths: *Path.Registry,
    fan_fd: std.posix.fd_t,
    root_dir: std.fs.Dir,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        paths: *Path.Registry,
        root_dir: std.fs.Dir,
    ) !Watcher {
        const fan_fd = try fanotify.fanotify_init(.{
            .CLASS = .NOTIF,
            .CLOEXEC = true,
            .REPORT_NAME = true,
            .REPORT_DIR_FID = true,
            .REPORT_FID = true,
            .REPORT_TARGET_FID = true,
        }, 0);

        return Watcher{
            .paths = paths,
            .root_dir = root_dir,
            .fan_fd = fan_fd,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Watcher) void {
        _ = self;
    }

    pub fn watchDir(self: *Watcher, path: Path) !void {
        // TODO: root project directory appears not to be marked correctly.
        try fanotify.fanotify_mark(
            self.fan_fd,
            .{ .ADD = true, .ONLYDIR = true },
            fan_mask,
            self.root_dir.fd,
            if (path.bytes().len == 0) null else path.bytes(),
        );
    }

    pub fn next(self: *Watcher) !Change {
        var events_buf: [256 + 4096]u8 = undefined;
        var len = try std.posix.read(self.fan_fd, &events_buf);
        const M = fanotify.fanotify.event_metadata;
        var meta: [*]align(1) M = @ptrCast(&events_buf);
        // TODO: return a single event
        while (len >= @sizeOf(M) and meta[0].event_len >= @sizeOf(M) and meta[0].event_len <= len) : ({
            len -= meta[0].event_len;
            meta = @ptrCast(@as([*]u8, @ptrCast(meta)) + meta[0].event_len);
        }) {
            // TODO: unsubscribe if directory was moved itself, and rescan parent.
            std.debug.assert(meta[0].vers == M.VERSION);
            if (meta[0].mask.Q_OVERFLOW) {
                std.debug.print("fanotify queue overflowed. Rescanning everything.\n", .{});
                return Change{
                    .is_dir = true,
                    .path = try self.paths.intern(""),
                };
            }
            const fid: *align(1) fanotify.fanotify.event_info_fid = @ptrCast(meta + 1);
            switch (fid.hdr.info_type) {
                .DFID_NAME => {
                    const file_handle: *align(1) fanotify.file_handle = @ptrCast(&fid.handle);
                    const file_name_z: [*:0]u8 = @ptrCast((&file_handle.f_handle).ptr + file_handle.handle_bytes);
                    const file_name = std.mem.span(file_name_z);
                    // TODO: what's this file_name? How do I get separated dir and file?
                    std.debug.print("FILE: {s}\n", .{file_name});
                    // TODO: perform shallow update when change happened in a directory
                    unreachable;
                },
                else => |t| {
                    std.debug.print("unexpected fanotify event '{s}'\n", .{@tagName(t)});
                    return error.UnexpectedFanotifyEvent;
                },
            }
        }
        unreachable;
    }

    const Change = struct {
        path: Path,
        is_dir: bool,
    };

    const fan_mask: fanotify.fanotify.MarkMask = .{
        .CLOSE_WRITE = true,
        .CREATE = true,
        .DELETE = true,
        .DELETE_SELF = true,
        .EVENT_ON_CHILD = true,
        .MOVED_FROM = true,
        .MOVED_TO = true,
        .MOVE_SELF = true,
        .ONDIR = true,
    };
};
