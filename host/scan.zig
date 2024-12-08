// Module responsible for scanning source files in the project directory and
// adding them onto the Site object.

const std = @import("std");
const glob = @import("glob.zig");
const fail = @import("fail.zig");
const WorkQueue = @import("work.zig").WorkQueue;
const Site = @import("site.zig").Site;
const TestSite = @import("site.zig").TestSite;
const Str = @import("str.zig").Str;
const Watcher = @import("watch.zig").Watcher(Str, Str.bytes);

pub fn scanDir(
    work: *WorkQueue,
    site: *Site,
    watcher: *Watcher,
    source_root: std.fs.Dir,
    dir_path: Str,
) !void {
    try watcher.watchDir(dir_path);
    var iterator = try SourceDirIterator.init(site, source_root, dir_path);
    while (try iterator.next()) |entry| {
        if (entry.is_dir) {
            try work.push(.{ .scan_dir = entry.path });
        } else {
            try site.ensurePage(entry.path);
            try work.push(.{ .scan_file = entry.path });
        }
    }
}

test scanDir {
    var test_site = try TestSite.init();
    defer test_site.deinit();
    var site = test_site.site;
    var rules = [_]Site.Rule{
        Site.Rule{
            .processing = .none,
            .patterns = try test_site.strsFromSlices(&.{"*"}),
            .replace_tags = &.{},
        },
    };
    site.rules = &rules;
    var work = WorkQueue.init(std.testing.allocator);
    defer work.deinit();
    var watcher = try Watcher.init(std.testing.allocator, site.source_root);
    defer watcher.deinit();

    try site.source_root.writeFile(.{ .sub_path = "c", .data = "" });
    try site.source_root.makeDir("b");
    try site.source_root.writeFile(.{ .sub_path = "a", .data = "" });

    try scanDir(
        &work,
        site,
        &watcher,
        site.source_root,
        try site.strs.intern(""),
    );

    try std.testing.expectEqualStrings("b", work.pop().?.scan_dir.bytes());
    try std.testing.expectEqualStrings("a", work.pop().?.scan_file.bytes());
    try std.testing.expectEqualStrings("c", work.pop().?.scan_file.bytes());
    try std.testing.expectEqual(null, work.pop());
}

pub fn scanFile(work: *WorkQueue, site: *Site, source_path: Str) !void {
    const changed = try site.scanPage(source_path);
    if (changed) try work.push(.{ .generate_file = source_path });
}

pub const SourceDirIterator = struct {
    iterator: std.fs.Dir.Iterator,
    site: *Site,
    dir_path: Str,

    const Entry = struct {
        path: Str,
        is_dir: bool,
    };

    pub fn init(site: *Site, source_root: std.fs.Dir, dir_path: Str) !SourceDirIterator {
        const path = if (dir_path.bytes().len == 0) "./" else dir_path.bytes();
        const dir = try source_root.openDir(path, .{ .iterate = true });
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
