// Module responsible for scanning source files in the project directory and
// adding them onto the Site object.

const std = @import("std");
const glob = @import("glob.zig");
const fail = @import("fail.zig");
const WorkQueue = @import("work.zig").WorkQueue;
const Site = @import("site.zig").Site;
const Str = @import("str.zig").Str;
const Watcher = @import("watch.zig").Watcher(Str, Str.bytes);

pub fn scanDir(
    work: *WorkQueue,
    strs: *Str.Registry,
    site: *Site,
    watcher: *Watcher,
    source_root: std.fs.Dir,
    dir_path: Str,
) !void {
    try watcher.watchDir(dir_path);
    const dir = if (dir_path.bytes().len == 0) blk: {
        break :blk source_root;
    } else blk: {
        break :blk try source_root.openDir(dir_path.bytes(), .{ .iterate = true });
    };
    var iterator = dir.iterateAssumeFirstIteration();
    while (true) {
        const entry = try iterator.next() orelse break;
        var buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const path_bytes = if (dir_path.bytes().len == 0) blk: {
            break :blk entry.name;
        } else blk: {
            break :blk try std.fmt.bufPrint(&buffer, "{s}/{s}", .{ dir_path.bytes(), entry.name });
        };
        if (glob.matchAny(site.ignore_patterns, path_bytes)) continue;

        const path = try strs.intern(path_bytes);
        switch (entry.kind) {
            .file => {
                try work.push(.{ .scan_file = path });
            },
            .directory => {
                try work.push(.{ .scan_dir = path });
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
}

test scanDir {
    var tmpdir = std.testing.tmpDir(.{ .iterate = true });
    defer tmpdir.cleanup();

    var strs = Str.Registry.init(std.testing.allocator);
    defer strs.deinit();

    var work = WorkQueue.init(std.testing.allocator);
    defer work.deinit();

    var site = try Site.init(std.testing.allocator, tmpdir.dir, "build.roc", "output", &strs);
    defer site.deinit();

    var watcher = try Watcher.init(std.testing.allocator, tmpdir.dir);
    defer watcher.deinit();

    try tmpdir.dir.writeFile(.{ .sub_path = "c", .data = "" });
    try tmpdir.dir.makeDir("b");
    try tmpdir.dir.writeFile(.{ .sub_path = "a", .data = "" });

    try scanDir(
        &work,
        &strs,
        &site,
        &watcher,
        tmpdir.dir,
        try strs.intern(""),
    );

    try std.testing.expectEqualStrings("b", work.pop().?.scan_dir.bytes());
    try std.testing.expectEqualStrings("a", work.pop().?.scan_file.bytes());
    try std.testing.expectEqualStrings("c", work.pop().?.scan_file.bytes());
    try std.testing.expectEqual(null, work.pop());
}

pub fn scanFile(work: *WorkQueue, site: *Site, source_path: Str) !void {
    const changed = try site.upsert(source_path);
    if (changed) try work.push(.{ .generate_file = source_path });
}
