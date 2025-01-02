// Recusrively watching the project directory for changes in source files.
// Currently only contains support for Linux using the fanotify API.

const std = @import("std");
const fanotify = @import("fanotify.zig");

pub fn Watcher(
    comptime Dir: type,
    comptime slice: fn (dir: Dir) []const u8,
) type {
    return struct {
        const Self = @This();

        // The fanotify filedescriptor, wrapped in a larger datastructure that
        // the poll syscall expects.
        poll_fds: [1]std.posix.pollfd,

        // The root path all dir strs passed in are assumed relative to.
        root_dir: std.fs.Dir,

        gpa: std.mem.Allocator,

        // Mapping internal file handles to directory identifiers used in API.
        dirs: std.ArrayHashMapUnmanaged(
            FileHandle,
            Dir,
            FileHandle.Adapter,
            false,
        ),

        // Buffer containing fanotify events. Stored as state so we can read
        // multiple events in one go and then parcel them out in subsequent
        // .next() calls.
        events_buf: [256 + 4096]u8,
        len: usize,
        offset: usize,

        pub fn init(
            gpa: std.mem.Allocator,
            root_dir: std.fs.Dir,
        ) !Self {
            const fan_fd = try fanotify.fanotify_init(.{
                .CLASS = .NOTIF,
                .CLOEXEC = true,
                .NONBLOCK = true,
                // The options below make it so fanotify events identify
                // modified files and directories using 'file handles' instead
                // of 'file descriptors'. File descriptors can be convenient
                // because they can immediately be used in further syscalls
                // reading/writing to the returned files/dirs, but they're a
                // limited resource. File handles are more convenient for our
                // purposes because we can have as many as we like.
                .REPORT_NAME = true,
                .REPORT_DIR_FID = true,
                .REPORT_FID = true,
                .REPORT_TARGET_FID = true,
            }, 0);

            return Self{
                .root_dir = root_dir,
                .poll_fds = .{
                    .{
                        .fd = fan_fd,
                        .events = std.posix.POLL.IN,
                        .revents = undefined,
                    },
                },
                .gpa = gpa,
                .dirs = .{},
                .events_buf = undefined,
                .len = 0,
                .offset = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.dirs.keys()) |key| key.destroy(self.gpa);
            self.dirs.deinit(self.gpa);
            std.posix.close(self.poll_fds[0].fd);
        }

        pub fn watchDir(self: *Self, dir: Dir) !void {
            const file_handle = try FileHandle.forDir(self.gpa, self.root_dir, slice(dir));
            errdefer file_handle.destroy(self.gpa);

            const get_or_put = try self.dirs.getOrPut(self.gpa, file_handle);
            if (get_or_put.found_existing) {
                file_handle.destroy(self.gpa);
                return;
            }

            get_or_put.value_ptr.* = dir;
            try fanotify.fanotify_mark(
                self.poll_fds[0].fd,
                .{ .ADD = true, .ONLYDIR = true },
                fan_mask,
                self.root_dir.fd,
                if (slice(dir).len == 0) "./" else slice(dir),
            );
        }

        pub fn unwatchDir(self: *Self, dir: Dir) !void {
            try fanotify.fanotify_mark(
                self.poll_fds[0].fd,
                .{ .REMOVE = true, .ONLYDIR = true },
                fan_mask,
                self.root_dir.fd,
                if (slice(dir).len == 0) "./" else slice(dir),
            );
        }

        const M = fanotify.fanotify.event_metadata;

        pub fn next(self: *Self) !?Change {
            var meta: [*]align(1) M = @ptrCast(@as([*]u8, @ptrCast(&self.events_buf)) + self.offset);
            if (self.len < @sizeOf(M) or
                meta[0].event_len < @sizeOf(M) or
                meta[0].event_len > self.len)
            {
                self.len = std.posix.read(self.poll_fds[0].fd, &self.events_buf) catch |err| {
                    return if (err == error.WouldBlock) null else err;
                };
                self.offset = 0;
                meta = @ptrCast(&self.events_buf);
            }
            self.len -= meta[0].event_len;
            self.offset += meta[0].event_len;
            std.debug.assert(meta[0].vers == M.VERSION);

            const mask = meta[0].mask;
            if (mask.Q_OVERFLOW) return .{ .changes_missed = void{} };

            const fid: *align(1) fanotify.fanotify.event_info_fid = @ptrCast(meta + 1);
            switch (fid.hdr.info_type) {
                .DFID_NAME => {},
                else => |t| {
                    std.debug.print("unexpected fanotify event '{s}'\n", .{@tagName(t)});
                    return error.UnexpectedFanotifyEvent;
                },
            }

            // Fanotify gives us a linux 'file_handle' struct, representing the
            // watched directory in which the change happened. It's directly
            // followed by a null-terminated byte representing the filename
            // in that directory modified.
            const file_handle: *align(1) fanotify.file_handle = @ptrCast(&fid.handle);
            const dir = self.dirs.get(.{ .handle = file_handle }) orelse {
                return error.ReceivedEventForUnwatchedDir;
            };
            const file_name_z: [*:0]u8 = @ptrCast((&file_handle.f_handle).ptr + file_handle.handle_bytes);
            const file_name = std.mem.span(file_name_z);

            return .{ .path_changed = .{ .dir = dir, .file_name = file_name } };
        }

        pub fn next_wait(self: *Self, max_wait_ms: i32) !?Change {
            if (try self.next()) |change| return change;
            const count = try std.posix.poll(&self.poll_fds, max_wait_ms);
            if (count > 0) return self.next();
            return null;
        }

        const fan_mask: fanotify.fanotify.MarkMask = .{
            .CLOSE_WRITE = true,
            .CREATE = true,
            .DELETE = true,
            .EVENT_ON_CHILD = true,
            .MOVED_FROM = true,
            .MOVED_TO = true,
            .ONDIR = true,
        };

        pub const Change = union(enum) {
            changes_missed: void,
            path_changed: struct {
                dir: Dir,
                file_name: []const u8,
            },
        };
    };
}

test "watching the same directory multiple times does not leak memory" {
    var tmpdir = std.testing.tmpDir(.{});
    defer tmpdir.cleanup();

    var watcher = try Watcher([]const u8, id).init(std.testing.allocator, tmpdir.parent_dir);
    defer watcher.deinit();

    try watcher.watchDir(&tmpdir.sub_path);
    try watcher.watchDir(&tmpdir.sub_path);
}

test "file watching produces expected events" {
    var rootdir = std.testing.tmpDir(.{});
    defer rootdir.cleanup();
    const root = rootdir.dir;

    var unwatcheddir = std.testing.tmpDir(.{});
    defer unwatcheddir.cleanup();
    const unwatched = unwatcheddir.dir;

    var watcher = try Watcher([]const u8, id).init(std.testing.allocator, root);
    defer watcher.deinit();

    try watcher.watchDir("");

    // Create a file triggers a change.
    try root.writeFile(.{ .sub_path = "test.txt", .data = "content" });
    try expectChange(&watcher, .{ .path_changed = .{ .dir = "", .file_name = "test.txt" } });

    // Opening, reading from, nor writing to a file triggers a change.
    var file = try root.openFile("test.txt", .{ .mode = .read_only });
    var buffer: [10]u8 = undefined;
    _ = try file.readAll(&buffer);
    file.close();

    file = try root.openFile("test.txt", .{ .mode = .write_only });
    try file.writeAll("more content");
    try std.testing.expectEqual(null, try watcher.next_wait(10));

    // Closing a file opened for writing triggers a change.
    file.close();
    try expectChange(&watcher, .{ .path_changed = .{ .dir = "", .file_name = "test.txt" } });

    // Moving a file out of the directory triggers a change.
    try std.fs.rename(root, "test.txt", unwatched, "backup.txt");
    try expectChange(&watcher, .{ .path_changed = .{ .dir = "", .file_name = "test.txt" } });

    // Moving a file into the watched directory triggers a change.
    try std.fs.rename(unwatched, "backup.txt", root, "test2.txt");
    try expectChange(&watcher, .{ .path_changed = .{ .dir = "", .file_name = "test2.txt" } });

    // Renaming a file triggers two changes for the old and new name.
    try root.rename("test2.txt", "test3.txt");
    try expectChange(&watcher, .{ .path_changed = .{ .dir = "", .file_name = "test2.txt" } });
    try expectChange(&watcher, .{ .path_changed = .{ .dir = "", .file_name = "test3.txt" } });

    // Deleting a file triggers a change.
    try root.deleteFile("test3.txt");
    try expectChange(&watcher, .{ .path_changed = .{ .dir = "", .file_name = "test3.txt" } });

    // Creating a subdirectory triggers a change.
    try root.makeDir("mid");
    try expectChange(&watcher, .{ .path_changed = .{ .dir = "", .file_name = "mid" } });

    var mid = try root.openDir("mid", .{});
    defer mid.close();
    try mid.makeDir("low");
    var low = try mid.openDir("low", .{});
    defer low.close();
    try watcher.watchDir("mid");
    try watcher.watchDir("mid/low");

    // Creating a file in a nested directry triggers a change.
    try mid.writeFile(.{ .sub_path = "test.txt", .data = "content" });
    try expectChange(&watcher, .{ .path_changed = .{ .dir = "mid", .file_name = "test.txt" } });

    // Moving a file between watched dirs triggers two changes.
    try std.fs.rename(mid, "test.txt", low, "test.txt");
    try expectChange(&watcher, .{ .path_changed = .{ .dir = "mid", .file_name = "test.txt" } });
    try expectChange(&watcher, .{ .path_changed = .{ .dir = "mid/low", .file_name = "test.txt" } });

    // Deleting a file from a directory after unwatching it triggers no change.
    var path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const abs_path = try mid.realpath("low", &path_buf);
    try watcher.unwatchDir(abs_path);
    try low.deleteFile("test.txt");
    try std.testing.expectEqual(null, try watcher.next_wait(10));

    // Moving a directory out of the project triggers a change.
    try std.fs.rename(mid, "low", unwatched, "low");
    try expectChange(&watcher, .{ .path_changed = .{ .dir = "mid", .file_name = "low" } });

    // Moving a directory into the project triggers a change.
    try std.fs.rename(unwatched, "low", mid, "low2");
    try expectChange(&watcher, .{ .path_changed = .{ .dir = "mid", .file_name = "low2" } });

    // Deleting a directory triggers a change for the directory.
    try mid.deleteDir("low2");
    try expectChange(&watcher, .{ .path_changed = .{ .dir = "mid", .file_name = "low2" } });
}

fn identity(path: []const u8) []const u8 {
    return path;
}

fn expectChange(
    watcher: *Watcher([]const u8, id),
    expected: Watcher([]const u8, identity).Change,
) !void {
    const actual = try watcher.next_wait(10) orelse return error.ExpectedEvent;
    try std.testing.expectEqualStrings(
        @tagName(std.meta.activeTag(expected)),
        @tagName(std.meta.activeTag(actual)),
    );
    const entries =
        switch (expected) {
        .changes_missed => return,
        .path_changed => .{ expected.path_changed, actual.path_changed },
    };
    try std.testing.expectEqualStrings(entries[0].dir, entries[1].dir);
    try std.testing.expectEqualStrings(entries[0].file_name, entries[1].file_name);
}

fn id(path: []const u8) []const u8 {
    return path;
}

// The code in this module is adapted from the std.Build.Watch Zig standard
// library
//
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
const FileHandle = struct {
    handle: *align(1) fanotify.file_handle,

    const Hash = std.hash.Wyhash;

    fn forDir(gpa: std.mem.Allocator, root_dir: std.fs.Dir, path: []const u8) !FileHandle {
        var file_handle_buffer: [@sizeOf(fanotify.file_handle) + 128]u8 align(@alignOf(fanotify.file_handle)) = undefined;
        var mount_id: i32 = undefined;
        var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const adjusted_path = if (path.len == 0)
            "./"
        else
            std.fmt.bufPrint(&buf, "{s}/", .{path}) catch return error.NameTooLong;
        const stack_ptr: *fanotify.file_handle = @ptrCast(&file_handle_buffer);
        stack_ptr.handle_bytes = file_handle_buffer.len - @sizeOf(fanotify.file_handle);
        try fanotify.name_to_handle_at(root_dir.fd, adjusted_path, stack_ptr, &mount_id, fanotify.HANDLE_FID);
        const stack_lfh: FileHandle = .{ .handle = stack_ptr };
        return stack_lfh.clone(gpa);
    }

    fn clone(lfh: FileHandle, gpa: std.mem.Allocator) std.mem.Allocator.Error!FileHandle {
        const bytes = lfh.slice();
        const new_ptr = try gpa.alignedAlloc(
            u8,
            @alignOf(fanotify.file_handle),
            @sizeOf(fanotify.file_handle) + bytes.len,
        );
        const new_header: *fanotify.file_handle = @ptrCast(new_ptr);
        new_header.* = lfh.handle.*;
        const new: FileHandle = .{ .handle = new_header };
        @memcpy(new.slice(), lfh.slice());
        return new;
    }

    fn destroy(lfh: FileHandle, gpa: std.mem.Allocator) void {
        const ptr: [*]u8 = @ptrCast(lfh.handle);
        const allocated_slice = ptr[0 .. @sizeOf(fanotify.file_handle) + lfh.handle.handle_bytes];
        return gpa.free(@as(
            []align(@alignOf(fanotify.file_handle)) u8,
            @alignCast(allocated_slice),
        ));
    }

    fn slice(lfh: FileHandle) []u8 {
        const ptr: [*]u8 = &lfh.handle.f_handle;
        return ptr[0..lfh.handle.handle_bytes];
    }

    const Adapter = struct {
        pub fn hash(self: Adapter, a: FileHandle) u32 {
            _ = self;
            const unsigned_type: u32 = @bitCast(a.handle.handle_type);
            return @truncate(Hash.hash(unsigned_type, a.slice()));
        }
        pub fn eql(self: Adapter, a: FileHandle, b: FileHandle, b_index: usize) bool {
            _ = self;
            _ = b_index;
            return a.handle.handle_type == b.handle.handle_type and std.mem.eql(u8, a.slice(), b.slice());
        }
    };
};
