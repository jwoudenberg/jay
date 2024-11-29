// The code in this module is adapted from the std.os.linux module in the
// Zig standard library, from commit 53a232e51d193ffc816347bda64921e869e6f32a
//
// The master branch contains some conveniences for working with fanotify that
// haven't landed in the latest stable release, 0.13.0 at time of writing. Once
// 0.14 lands I'll switch to that and delete this module.
// The license for Zig project is included below.

// The MIT License (Expat)
//
// Copyright (c) Zig contributors
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

const std = @import("std");
const builtin = @import("builtin");
const native_arch = builtin.cpu.arch;
const native_endian = native_arch.endian();

pub fn fanotify_init(flags: fanotify.InitFlags, event_f_flags: u32) !i32 {
    const rc = std.os.linux.fanotify_init(@as(u32, @bitCast(flags)), event_f_flags);
    switch (std.posix.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .INVAL => return error.UnsupportedFlags,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOMEM => return error.SystemResources,
        .PERM => return error.PermissionDenied,
        else => |err| return std.posix.unexpectedErrno(err),
    }
}

pub fn fanotify_mark(
    fanotify_fd: std.posix.fd_t,
    flags: fanotify.MarkFlags,
    mask: fanotify.MarkMask,
    dirfd: std.posix.fd_t,
    pathname: ?[]const u8,
) !void {
    if (pathname) |path| {
        const path_c = try std.posix.toPosixPath(path);
        return fanotify_markZ(fanotify_fd, flags, mask, dirfd, &path_c);
    } else {
        return fanotify_markZ(fanotify_fd, flags, mask, dirfd, null);
    }
}

pub fn fanotify_markZ(
    fanotify_fd: std.posix.fd_t,
    flags: fanotify.MarkFlags,
    mask: fanotify.MarkMask,
    dirfd: std.posix.fd_t,
    pathname: ?[*:0]const u8,
) !void {
    const rc = std.os.linux.fanotify_mark(
        fanotify_fd,
        @as(u32, @bitCast(flags)),
        @bitCast(mask),
        dirfd,
        pathname,
    );
    switch (std.posix.errno(rc)) {
        .SUCCESS => return,
        .BADF => unreachable,
        .EXIST => return error.MarkAlreadyExists,
        .INVAL => unreachable,
        .ISDIR => return error.IsDir,
        .NODEV => return error.NotAssociatedWithFileSystem,
        .NOENT => return error.FileNotFound,
        .NOMEM => return error.SystemResources,
        .NOSPC => return error.UserMarkQuotaExceeded,
        .NOTDIR => return error.NotDir,
        .OPNOTSUPP => return error.OperationNotSupported,
        .PERM => return error.PermissionDenied,
        .XDEV => return error.NotSameFileSystem,
        else => |err| return std.posix.unexpectedErrno(err),
    }
}

pub const fanotify = struct {
    pub const InitFlags = packed struct(u32) {
        CLOEXEC: bool = false,
        NONBLOCK: bool = false,
        CLASS: enum(u2) {
            NOTIF = 0,
            CONTENT = 1,
            PRE_CONTENT = 2,
        } = .NOTIF,
        UNLIMITED_QUEUE: bool = false,
        UNLIMITED_MARKS: bool = false,
        ENABLE_AUDIT: bool = false,
        REPORT_PIDFD: bool = false,
        REPORT_TID: bool = false,
        REPORT_FID: bool = false,
        REPORT_DIR_FID: bool = false,
        REPORT_NAME: bool = false,
        REPORT_TARGET_FID: bool = false,
        _: u19 = 0,
    };

    pub const MarkFlags = packed struct(u32) {
        ADD: bool = false,
        REMOVE: bool = false,
        DONT_FOLLOW: bool = false,
        ONLYDIR: bool = false,
        MOUNT: bool = false,
        /// Mutually exclusive with `IGNORE`
        IGNORED_MASK: bool = false,
        IGNORED_SURV_MODIFY: bool = false,
        FLUSH: bool = false,
        FILESYSTEM: bool = false,
        EVICTABLE: bool = false,
        /// Mutually exclusive with `IGNORED_MASK`
        IGNORE: bool = false,
        _: u21 = 0,
    };

    pub const MarkMask = packed struct(u64) {
        /// File was accessed
        ACCESS: bool = false,
        /// File was modified
        MODIFY: bool = false,
        /// Metadata changed
        ATTRIB: bool = false,
        /// Writtable file closed
        CLOSE_WRITE: bool = false,
        /// Unwrittable file closed
        CLOSE_NOWRITE: bool = false,
        /// File was opened
        OPEN: bool = false,
        /// File was moved from X
        MOVED_FROM: bool = false,
        /// File was moved to Y
        MOVED_TO: bool = false,

        /// Subfile was created
        CREATE: bool = false,
        /// Subfile was deleted
        DELETE: bool = false,
        /// Self was deleted
        DELETE_SELF: bool = false,
        /// Self was moved
        MOVE_SELF: bool = false,
        /// File was opened for exec
        OPEN_EXEC: bool = false,
        reserved13: u1 = 0,
        /// Event queued overflowed
        Q_OVERFLOW: bool = false,
        /// Filesystem error
        FS_ERROR: bool = false,

        /// File open in perm check
        OPEN_PERM: bool = false,
        /// File accessed in perm check
        ACCESS_PERM: bool = false,
        /// File open/exec in perm check
        OPEN_EXEC_PERM: bool = false,
        reserved19: u8 = 0,
        /// Interested in child events
        EVENT_ON_CHILD: bool = false,
        /// File was renamed
        RENAME: bool = false,
        reserved30: u1 = 0,
        /// Event occurred against dir
        ONDIR: bool = false,
        reserved31: u33 = 0,
    };

    pub const event_metadata = extern struct {
        event_len: u32,
        vers: u8,
        reserved: u8,
        metadata_len: u16,
        mask: MarkMask align(8),
        fd: i32,
        pid: i32,

        pub const VERSION = 3;
    };

    pub const response = extern struct {
        fd: i32,
        response: u32,
    };

    /// Unique file identifier info record.
    ///
    /// This structure is used for records of types `EVENT_INFO_TYPE.FID`.
    /// `EVENT_INFO_TYPE.DFID` and `EVENT_INFO_TYPE.DFID_NAME`.
    ///
    /// For `EVENT_INFO_TYPE.DFID_NAME` there is additionally a null terminated
    /// name immediately after the file handle.
    pub const event_info_fid = extern struct {
        hdr: event_info_header,
        fsid: kernel_fsid_t,
        /// Following is an opaque struct file_handle that can be passed as
        /// an argument to open_by_handle_at(2).
        handle: [0]u8,
    };

    /// Variable length info record following event metadata.
    pub const event_info_header = extern struct {
        info_type: EVENT_INFO_TYPE,
        pad: u8,
        len: u16,
    };

    pub const EVENT_INFO_TYPE = enum(u8) {
        FID = 1,
        DFID_NAME = 2,
        DFID = 3,
        PIDFD = 4,
        ERROR = 5,
        OLD_DFID_NAME = 10,
        OLD_DFID = 11,
        NEW_DFID_NAME = 12,
        NEW_DFID = 13,
    };
};

pub const file_handle = extern struct {
    handle_bytes: u32,
    handle_type: i32,
    f_handle: [0]u8,
};

pub const kernel_fsid_t = fsid_t;
pub const fsid_t = [2]i32;

pub fn name_to_handle_at(
    dirfd: std.posix.fd_t,
    pathname: []const u8,
    handle: *file_handle,
    mount_id: *i32,
    flags: u32,
) !void {
    const pathname_c = try toPosixPath(pathname);
    return name_to_handle_atZ(dirfd, &pathname_c, handle, mount_id, flags);
}

pub fn name_to_handle_atZ(
    dirfd: std.posix.fd_t,
    pathname_z: [*:0]const u8,
    handle: *file_handle,
    mount_id: *i32,
    flags: u32,
) !void {
    switch (std.posix.errno(linux_name_to_handle_at(dirfd, pathname_z, handle, mount_id, flags))) {
        .SUCCESS => {},
        .FAULT => unreachable, // pathname, mount_id, or handle outside accessible address space
        .INVAL => unreachable, // bad flags, or handle_bytes too big
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .OPNOTSUPP => return error.OperationNotSupported,
        .OVERFLOW => return error.NameTooLong,
        else => |err| return std.posix.unexpectedErrno(err),
    }
}

pub fn linux_name_to_handle_at(
    dirfd: std.posix.fd_t,
    pathname: [*:0]const u8,
    handle: *file_handle,
    mount_id: *i32,
    flags: u32,
) usize {
    return std.os.linux.syscall5(
        .name_to_handle_at,
        @as(u32, @bitCast(dirfd)),
        @intFromPtr(pathname),
        @intFromPtr(handle),
        @intFromPtr(mount_id),
        flags,
    );
}

// Used to convert a slice to a null terminated slice on the stack.
pub fn toPosixPath(file_path: []const u8) error{NameTooLong}![std.posix.PATH_MAX - 1:0]u8 {
    if (std.debug.runtime_safety) std.debug.assert(std.mem.indexOfScalar(u8, file_path, 0) == null);
    var path_with_null: [std.posix.PATH_MAX - 1:0]u8 = undefined;
    // >= rather than > to make room for the null byte
    if (file_path.len >= std.posix.PATH_MAX) return error.NameTooLong;
    @memcpy(path_with_null[0..file_path.len], file_path);
    path_with_null[file_path.len] = 0;
    return path_with_null;
}

pub const HANDLE_FID = std.os.linux.AT.REMOVEDIR;
