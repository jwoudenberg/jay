// Module responsible for scanning source files in the project directory and
// adding them onto the Site object.

const std = @import("std");
const glob = @import("glob.zig");
const fail = @import("fail.zig");
const Site = @import("site.zig").Site;
const TestSite = @import("site.zig").TestSite;
const Str = @import("str.zig").Str;
const Watcher = @import("watch.zig").Watcher(Str, Str.bytes);

pub fn scanRecursively(
    gpa: std.mem.Allocator,
    site: *Site,
    watcher: anytype,
    init_dir: Str,
) !void {
    var scan_queue = std.ArrayList(Str).init(gpa);
    defer scan_queue.deinit();
    try scan_queue.append(init_dir);
    while (scan_queue.popOrNull()) |dir| {
        try watcher.watchDir(dir);
        var iterator = try SourceDirIterator.init(site, site.source_root, dir) orelse continue;
        while (try iterator.next()) |entry| {
            if (entry.is_dir) {
                try scan_queue.append(entry.path);
            } else {
                try site.touchPage(entry.path);
            }
        }
    }
}

test scanRecursively {
    var test_site = try TestSite.init(.{
        .static_patterns = &.{ "*", "dir/*" },
    });
    defer test_site.deinit();
    var site = test_site.site;
    var watcher = try Watcher.init(std.testing.allocator, site.source_root);
    defer watcher.deinit();

    try site.source_root.makeDir("dir");
    try site.source_root.writeFile(.{ .sub_path = "one", .data = "" });
    try site.source_root.writeFile(.{ .sub_path = "two", .data = "" });
    try site.source_root.writeFile(.{ .sub_path = "dir/three", .data = "" });

    try scanRecursively(
        std.testing.allocator,
        site,
        &watcher,
        try site.strs.intern(""),
    );

    try std.testing.expect(null != site.getPage(try site.strs.intern("one")));
    try std.testing.expect(null != site.getPage(try site.strs.intern("two")));
    try std.testing.expect(null != site.getPage(try site.strs.intern("dir/three")));
}

pub const SourceDirIterator = struct {
    iterator: std.fs.Dir.Iterator,
    site: *Site,
    dir_path: Str,

    const Entry = struct {
        path: Str,
        is_dir: bool,
    };

    pub fn init(site: *Site, source_root: std.fs.Dir, dir_path: Str) !?SourceDirIterator {
        const path = if (dir_path.bytes().len == 0) "./" else dir_path.bytes();
        const dir = source_root.openDir(path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) {
                return null;
            } else {
                return err;
            }
        };
        const iterator = dir.iterate();
        return .{
            .iterator = iterator,
            .site = site,
            .dir_path = dir_path,
        };
    }

    pub fn next(self: *SourceDirIterator) !?Entry {
        var buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        while (true) {
            const entry = try self.iterator.next() orelse break;
            const path_bytes = if (self.dir_path.bytes().len == 0) blk: {
                break :blk entry.name;
            } else blk: {
                break :blk try std.fmt.bufPrint(
                    &buffer,
                    "{s}/{s}",
                    .{ self.dir_path.bytes(), entry.name },
                );
            };
            if (Site.matchAny(self.site.ignore_patterns, path_bytes)) continue;

            const path = try self.site.strs.intern(path_bytes);
            switch (entry.kind) {
                .file => {
                    return .{
                        .path = path,
                        .is_dir = false,
                    };
                },
                .directory => {
                    return .{
                        .path = path,
                        .is_dir = true,
                    };
                },
                .block_device,
                .character_device,
                .named_pipe,
                .sym_link,
                .unix_domain_socket,
                .whiteout,
                .door,
                .event_port,
                .unknown,
                => {
                    try fail.prettily(
                        \\Encountered a path of type {s}:
                        \\
                        \\    {s}
                        \\
                        \\I don't support generating pages from this type of file!
                        \\
                        \\Tip: Remove the path from the source directory.
                    , .{ @tagName(entry.kind), path.bytes() });
                },
            }
        }
        return null;
    }
};
