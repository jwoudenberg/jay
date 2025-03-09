// The code in this module is adapted from the std.posix module in the
// Zig standard library, from commit 53a232e51d193ffc816347bda64921e869e6f32a
//
// I'm having trouble calling these functions from std.posix.<name> directly,
// getting a compiler error. Until I figure out a better fix, below are
// adapted versions of the functions I need.

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
const fanotify = std.os.linux.fanotify;

pub fn fanotify_init(flags: fanotify.InitFlags, event_f_flags: u32) !i32 {
    const rc = std.os.linux.fanotify_init(flags, event_f_flags);
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
        flags,
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

pub fn name_to_handle_at(
    dirfd: std.posix.fd_t,
    pathname: []const u8,
    handle: *std.os.linux.file_handle,
    mount_id: *i32,
    flags: u32,
) !void {
    const pathname_c = try std.posix.toPosixPath(pathname);
    return name_to_handle_atZ(dirfd, &pathname_c, handle, mount_id, flags);
}

pub fn name_to_handle_atZ(
    dirfd: std.posix.fd_t,
    pathname_z: [*:0]const u8,
    handle: *std.os.linux.file_handle,
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
    handle: *std.os.linux.file_handle,
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
