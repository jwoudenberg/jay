// Module responsible for scanning source files in the project directory and
// adding them onto the Site object.

const std = @import("std");
const glob = @import("glob.zig");
const fail = @import("fail.zig");
const Site = @import("site.zig").Site;
const TestSite = @import("site.zig").TestSite;
const Str = @import("str.zig").Str;
const Watcher = @import("watch.zig").Watcher;

pub fn scanRecursively(
    gpa: std.mem.Allocator,
    site: *Site,
    watcher: anytype,
    init_path: []const u8,
) !void {
    const Filter = struct {
        const Self = @This();
        site: *Site,
        pub fn keep(self: *Self, path: []const u8) bool {
            return !Site.matchAny(self.site.ignore_patterns, path);
        }
    };
    var scanner = Scanner(Filter).init(
        gpa,
        site.strs,
        Filter{ .site = site },
        site.source_root,
    );
    defer scanner.deinit();
    try scanner.scan(init_path);
    while (try scanner.next()) |entry| {
        switch (entry.is_dir) {
            .yes => {
                try watcher.watchDir(entry.path);
                try site.touchPath(entry.path, true);
            },
            .unsure => {
                try site.touchPath(entry.path, false);
            },
        }
    }
}

test scanRecursively {
    var test_site = try TestSite.init(.{
        .static_patterns = &.{ "*", "dir/*" },
    });
    defer test_site.deinit();
    var site = test_site.site;
    // TODO: Use custom tmpdir implementation that gives relative path to
    // tmpdir, to avoid use of `realpath`.
    const source_root_path = try site.source_root.realpathAlloc(std.testing.allocator, "./");
    defer std.testing.allocator.free(source_root_path);
    const watcher = try Watcher.init(std.testing.allocator, source_root_path);
    defer watcher.deinit();

    try site.source_root.makeDir("dir");
    try site.source_root.writeFile(.{ .sub_path = "one", .data = "" });
    try site.source_root.writeFile(.{ .sub_path = "two", .data = "" });
    try site.source_root.writeFile(.{ .sub_path = "dir/three", .data = "" });

    try scanRecursively(
        std.testing.allocator,
        site,
        watcher,
        "",
    );

    try std.testing.expect(null != site.getPage(try site.strs.intern("one")));
    try std.testing.expect(null != site.getPage(try site.strs.intern("two")));
    try std.testing.expect(null != site.getPage(try site.strs.intern("dir/three")));
}

pub fn Scanner(Filter: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        strs: Str.Registry,
        queue: std.SegmentedList(Str, 0),
        source_root: std.fs.Dir,
        filter: Filter,
        current_dir: ?CurrentDir,

        const CurrentDir = struct {
            sub_path: Str,
            dir: std.fs.Dir,
            iterator: std.fs.Dir.Iterator,
        };

        const Entry = struct {
            path: Str,
            is_dir: enum { yes, unsure },
        };

        pub fn init(
            allocator: std.mem.Allocator,
            strs: Str.Registry,
            filter: Filter,
            source_root: std.fs.Dir,
        ) Self {
            return .{
                .allocator = allocator,
                .strs = strs,
                .filter = filter,
                .source_root = source_root,
                .queue = std.SegmentedList(Str, 0){},
                .current_dir = null,
            };
        }

        pub fn deinit(self: *Self) void {
            self.endCurrentDir();
            self.queue.deinit(self.allocator);
        }

        pub fn scan(self: *Self, path: []const u8) !void {
            const interned = try self.strs.intern(path);
            if (self.filter.keep(path)) {
                try self.queue.append(self.allocator, interned);
            }
        }

        pub fn next(self: *Self) !?Entry {
            return while (true) {
                // Continue scanning the current directory, or else get the next
                // path from the scan queue.

                if (self.current_dir) |*current| {
                    if (try current.iterator.next()) |iter_entry| {
                        const path = if (current.sub_path.bytes().len == 0)
                            iter_entry.name
                        else blk: {
                            var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
                            break :blk try std.fmt.bufPrint(
                                &buf,
                                "{s}/{s}",
                                .{ current.sub_path.bytes(), iter_entry.name },
                            );
                        };
                        try self.scan(path);
                        continue;
                    } else {
                        self.endCurrentDir();
                    }
                }

                if (self.queue.pop()) |path| {
                    // We want to support symlinks as regular files/directories,
                    // and need a reliable way to figure out if a path refers
                    // to a directory or not, regardless of whether the path is
                    // a symlink. The easiest way to do this is to try to open
                    // the path as a directory.
                    if (self.source_root.openDir(
                        if (path.bytes().len == 0) "./" else path.bytes(),
                        .{ .iterate = true },
                    )) |dir| {
                        self.current_dir = .{
                            .sub_path = path,
                            .dir = dir,
                            .iterator = dir.iterate(),
                        };
                        return .{
                            .path = path,
                            .is_dir = .yes,
                        };
                    } else |_| {
                        // We expect to typicall see error.NotDir in this
                        // branch, but even if it's something else we'll
                        // continue at this point. We'll `stat` the file in
                        // Site and will handle errors there.
                        return .{
                            .path = path,
                            .is_dir = .unsure,
                        };
                    }
                }

                return null;
            };
        }

        pub fn endCurrentDir(self: *Self) void {
            if (self.current_dir) |current| {
                var dir = current.dir;
                dir.close();
                self.current_dir = null;
            }
        }
    };
}
