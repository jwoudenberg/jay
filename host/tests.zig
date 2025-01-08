// Run tests on this module to ensure they run on all the modules below.

const std = @import("std");
const Watcher = @import("watch.zig").Watcher(Str, Str.bytes);
const scanRecursively = @import("scan.zig").scanRecursively;
const Str = @import("str.zig").Str;
const RunLoop = @import("main.zig").RunLoop;
const handleChange = @import("main.zig").handleChange;

comptime {
    _ = @import("argparse.zig");
    _ = @import("bitset.zig");
    _ = @import("bootstrap.zig");
    _ = @import("error.zig");
    _ = @import("fail.zig");
    _ = @import("frontmatter.zig");
    _ = @import("generate.zig");
    _ = @import("glob.zig");
    _ = @import("highlight.zig");
    _ = @import("main.zig");
    _ = @import("markdown.zig");
    _ = @import("str.zig");
    _ = @import("platform.zig");
    _ = @import("scan.zig");
    _ = @import("serve.zig");
    _ = @import("site.zig");
    _ = @import("watch.zig");
    _ = @import("watch-linux.zig");
    _ = @import("xml.zig");
}

test "add a source file => jay generates an output file for it" {
    var test_run_loop = try TestRunLoop.init(.{ .markdown_patterns = &.{"*.md"} });
    defer test_run_loop.deinit();
    var site = test_run_loop.test_site.site;

    try site.source_root.writeFile(.{ .sub_path = "file.md", .data = "{}<html/>" });
    try test_run_loop.loopOnce();
    try std.testing.expectEqualStrings("", test_run_loop.output());
    try expectFile(site.output_root, "file.html", "<html/>\n");
}

test "add a markdown source file without frontmatter => jay generates an output file for it" {
    var test_run_loop = try TestRunLoop.init(.{ .markdown_patterns = &.{"*.md"} });
    defer test_run_loop.deinit();
    var site = test_run_loop.test_site.site;

    try site.source_root.writeFile(.{ .sub_path = "file.md", .data = "<html/>" });
    try test_run_loop.loopOnce();
    try std.testing.expectEqualStrings("", test_run_loop.output());
    try expectFile(site.output_root, "file.html", "<html/>\n");
}

test "delete a source file => jay deletes its output file" {
    var test_run_loop = try TestRunLoop.init(.{ .markdown_patterns = &.{"*.md"} });
    defer test_run_loop.deinit();
    var site = test_run_loop.test_site.site;

    try site.source_root.writeFile(.{ .sub_path = "file.md", .data = "{}<html/>" });
    try test_run_loop.loopOnce();
    try expectFile(site.output_root, "file.html", "<html/>\n");

    try site.source_root.deleteFile("file.md");
    try test_run_loop.loopOnce();
    try expectNoFile(site.output_root, "file.html");
}

test "delete a source file before a page is generated => jay does not create an output file" {
    var test_run_loop = try TestRunLoop.init(.{
        .markdown_patterns = &.{"*.md"},
        .static_patterns = &.{"static*"},
    });
    defer test_run_loop.deinit();
    var site = test_run_loop.test_site.site;
    var run_loop = test_run_loop.run_loop;

    // Test for three file types that we know generate has separate logic for.
    try site.source_root.writeFile(.{ .sub_path = "file.md", .data = "{}<html/>" });
    try site.source_root.writeFile(.{ .sub_path = "static.css", .data = "" });
    try site.source_root.writeFile(.{ .sub_path = "static.html", .data = "" });
    while (try run_loop.watcher.next_wait(50)) |change| {
        try handleChange(std.testing.allocator, site, run_loop.watcher, change);
    }
    try expectNoFile(site.output_root, "file");
    try expectNoFile(site.output_root, "static.css");
    try expectNoFile(site.output_root, "static");

    try site.source_root.deleteFile("file.md");
    try site.source_root.deleteFile("static.css");
    try site.source_root.deleteFile("static.html");
    try test_run_loop.loopOnce();
    try expectNoFile(site.output_root, "file");
    try expectNoFile(site.output_root, "static.css");
    try expectNoFile(site.output_root, "static");
}

test "create a short-lived file that does not match a pattern => jay will not show an error" {
    var test_run_loop = try TestRunLoop.init(.{});
    defer test_run_loop.deinit();
    var site = test_run_loop.test_site.site;

    try site.source_root.writeFile(.{ .sub_path = "file.md", .data = "{}<html/>" });
    try site.source_root.deleteFile("file.md");
    try test_run_loop.loopOnce();
    try expectNoFile(site.output_root, "file.html");
    try std.testing.expectEqualStrings("", test_run_loop.output());
}

test "move a directory out of project dir => jay recursively deletes related output files" {
    var test_run_loop = try TestRunLoop.init(.{ .markdown_patterns = &.{
        "*.md",
        "cellar/subway/*.md",
    } });
    defer test_run_loop.deinit();
    var extern_dir = std.testing.tmpDir(.{});
    defer extern_dir.cleanup();
    var site = test_run_loop.test_site.site;

    try site.source_root.makePath("cellar/subway");
    try site.source_root.writeFile(.{ .sub_path = "file1.md", .data = "{}<html/>" });
    try site.source_root.writeFile(.{ .sub_path = "cellar/subway/file2.md", .data = "{}<html/>" });
    try test_run_loop.loopOnce();
    try expectFile(site.output_root, "file1.html", "<html/>\n");
    try expectFile(site.output_root, "cellar/subway/file2.html", "<html/>\n");

    try std.fs.rename(site.source_root, "cellar", extern_dir.dir, "cellar");
    try test_run_loop.loopOnce();
    try expectFile(site.output_root, "file1.html", "<html/>\n");
    try expectNoFile(site.output_root, "cellar/subway/file2.html");
    try std.testing.expectEqualStrings("", test_run_loop.output());

    // Changing a file after it's been moved out of the project has no effect
    try extern_dir.dir.writeFile(.{ .sub_path = "cellar/subway/file2.md", .data = "{}<span/>" });
    try test_run_loop.loopOnce();
    try expectNoFile(site.output_root, "cellar/subway/file2.html");
    try std.testing.expectEqualStrings("", test_run_loop.output());
}

test "move a directory with a file into the project dir => jay generates an output file" {
    var test_run_loop = try TestRunLoop.init(.{ .markdown_patterns = &.{
        "cellar/subway/*.md",
    } });
    defer test_run_loop.deinit();
    var extern_dir = std.testing.tmpDir(.{});
    defer extern_dir.cleanup();
    const site = test_run_loop.test_site.site;

    try extern_dir.dir.makePath("cellar/subway");
    try extern_dir.dir.writeFile(.{ .sub_path = "cellar/subway/file.md", .data = "{}<html/>" });

    try std.fs.rename(extern_dir.dir, "cellar", site.source_root, "cellar");
    try test_run_loop.loopOnce();
    try expectFile(site.output_root, "cellar/subway/file.html", "<html/>\n");
    try std.testing.expectEqualStrings("", test_run_loop.output());
}

test "create a directory then later a file in it => jay generates an output file" {
    var test_run_loop = try TestRunLoop.init(.{ .markdown_patterns = &.{
        "cellar/*.md",
    } });
    defer test_run_loop.deinit();
    const site = test_run_loop.test_site.site;

    try site.source_root.makePath("cellar");
    try test_run_loop.loopOnce();

    try site.source_root.writeFile(.{ .sub_path = "cellar/file.md", .data = "{}<html/>" });
    try test_run_loop.loopOnce();
    try expectFile(site.output_root, "cellar/file.html", "<html/>\n");
    try std.testing.expectEqualStrings("", test_run_loop.output());
}

test "add a file matching an ignore pattern => jay does not generate an output file nor show an error" {
    var test_run_loop = try TestRunLoop.init(.{ .ignore_patterns = &.{"*.md"} });
    defer test_run_loop.deinit();
    const site = test_run_loop.test_site.site;

    try site.source_root.writeFile(.{ .sub_path = "file.md", .data = "{}<html/>" });
    try test_run_loop.loopOnce();
    try expectNoFile(site.output_root, "file.html");
    try std.testing.expectEqualStrings("", test_run_loop.output());
}

test "add a file that does not match a pattern => jay will show an error" {
    var test_run_loop = try TestRunLoop.init(.{ .markdown_patterns = &.{} });
    defer test_run_loop.deinit();
    const site = test_run_loop.test_site.site;

    try site.source_root.writeFile(.{ .sub_path = "file.md", .data = "{}<html/>" });
    try test_run_loop.loopOnce();
    try expectNoFile(site.output_root, "file.html");
    try std.testing.expectEqualStrings(
        \\I can't find a pattern matching the following source path:
        \\
        \\    file.md
        \\
        \\Make sure each path in your project directory is matched by
        \\a rule, or an ignore pattern.
        \\
        \\Tip: Add an extra rule like this:
        \\
        \\    Pages.files ["file.md"]
        \\
        \\
    , test_run_loop.output());

    // Remove the file => jay marks the error fixed
    try site.source_root.deleteFile("file.md");
    try test_run_loop.loopOnce();
    try std.testing.expectEqualStrings("", test_run_loop.output());
}

test "add multiple files with a problem => jay will show multiple error" {
    var test_run_loop = try TestRunLoop.init(.{ .markdown_patterns = &.{} });
    defer test_run_loop.deinit();
    const site = test_run_loop.test_site.site;

    try site.source_root.writeFile(.{ .sub_path = "file1.md", .data = "{}<html/>" });
    try site.source_root.writeFile(.{ .sub_path = "file2.md", .data = "{}<html/>" });
    try test_run_loop.loopOnce();
    try std.testing.expectEqualStrings(
        \\I can't find a pattern matching the following source path:
        \\
        \\    file1.md
        \\
        \\Make sure each path in your project directory is matched by
        \\a rule, or an ignore pattern.
        \\
        \\Tip: Add an extra rule like this:
        \\
        \\    Pages.files ["file1.md"]
        \\
        \\
        \\----------------------------------------
        \\
        \\I can't find a pattern matching the following source path:
        \\
        \\    file2.md
        \\
        \\Make sure each path in your project directory is matched by
        \\a rule, or an ignore pattern.
        \\
        \\Tip: Add an extra rule like this:
        \\
        \\    Pages.files ["file2.md"]
        \\
        \\
    , test_run_loop.output());

    // Fix one problem => jay continues to show the remaining problem
    try site.source_root.deleteFile("file1.md");
    try test_run_loop.loopOnce();
    try std.testing.expectEqualStrings(
        \\I can't find a pattern matching the following source path:
        \\
        \\    file2.md
        \\
        \\Make sure each path in your project directory is matched by
        \\a rule, or an ignore pattern.
        \\
        \\Tip: Add an extra rule like this:
        \\
        \\    Pages.files ["file2.md"]
        \\
        \\
    , test_run_loop.output());
}

test "add a file that matches two patterns of the same rule => jay does not show an error" {
    var test_run_loop = try TestRunLoop.init(.{ .markdown_patterns = &.{ "*.md", "file*" } });
    defer test_run_loop.deinit();
    const site = test_run_loop.test_site.site;

    try site.source_root.writeFile(.{ .sub_path = "file.md", .data = "{}<html/>" });
    try test_run_loop.loopOnce();
    try expectFile(site.output_root, "file.html", "<html/>\n");
    try std.testing.expectEqualStrings("", test_run_loop.output());
}

test "add a file matching patterns in two rules => jay shows an error" {
    var test_run_loop = try TestRunLoop.init(.{
        .markdown_patterns = &.{"*.md"},
        .static_patterns = &.{"file*"},
    });
    defer test_run_loop.deinit();
    const site = test_run_loop.test_site.site;

    try site.source_root.writeFile(.{ .sub_path = "file.md", .data = "{}<html/>" });
    try test_run_loop.loopOnce();
    try expectNoFile(site.output_root, "file.html");
    try std.testing.expectEqualStrings(
        \\The following file is matched by multiple rules:
        \\
        \\    file.md
        \\
        \\These are the indices of the rules that match:
        \\
        \\    { 0, 1 }
        \\
        \\
    , test_run_loop.output());

    // Remove the file => jay marks the error fixed
    try site.source_root.deleteFile("file.md");
    try test_run_loop.loopOnce();
    try std.testing.expectEqualStrings("", test_run_loop.output());
}

test "add two files that output the same web path => jay shows an error" {
    var test_run_loop = try TestRunLoop.init(.{
        .markdown_patterns = &.{"*.md"},
        .static_patterns = &.{"*.html"},
    });
    defer test_run_loop.deinit();
    const site = test_run_loop.test_site.site;

    try site.source_root.writeFile(.{ .sub_path = "file.md", .data = "{}<html/>" });
    try site.source_root.writeFile(.{ .sub_path = "file.html", .data = "<span/>" });
    try test_run_loop.loopOnce();
    try expectFile(site.output_root, "file.html", "<html/>\n");
    try std.testing.expectEqualStrings(
        \\I found multiple source files for a single page URL.
        \\
        \\These are the source files in question:
        \\
        \\  file.html
        \\  file.md
        \\
        \\The URL path I would use for both of these is:
        \\
        \\  file
        \\
        \\Tip: Rename one of the files so both get a unique URL.
        \\
    , test_run_loop.output());

    // TODO: make this problem recoverable.
    // // Remove one of the files => jay marks the error fixed
    // try site.source_root.deleteFile("file.md");
    // try test_run_loop.loopOnce();
    // try expectFile(site.output_root, "file.html", "<span/>\n");
    // try std.testing.expectEqualStrings("", test_run_loop.output());
}

test "change a file => jay updates the file and its dependents" {
    var test_run_loop = try TestRunLoop.init(.{ .markdown_patterns = &.{"*.md"} });
    defer test_run_loop.deinit();
    const site = test_run_loop.test_site.site;

    try site.source_root.writeFile(.{ .sub_path = "dep.md", .data = "{ hi: 4 }<html/>" });
    try site.source_root.writeFile(.{ .sub_path = "file.md", .data = "{}<dep pattern=\"dep*\"/>" });
    try test_run_loop.loopOnce();
    try expectFile(site.output_root, "dep.html", "<html/>\n");
    try expectFile(site.output_root, "file.html", "{ hi: 4 }\n");

    try site.source_root.writeFile(.{ .sub_path = "dep.md", .data = "{ hi: 5 }<xml/>" });
    try test_run_loop.loopOnce();
    try expectFile(site.output_root, "dep.html", "<xml/>\n");
    try expectFile(site.output_root, "file.html", "{ hi: 5 }\n");
}

test "add a file => jay updates dependents" {
    var test_run_loop = try TestRunLoop.init(.{ .markdown_patterns = &.{"*.md"} });
    defer test_run_loop.deinit();
    const site = test_run_loop.test_site.site;

    try site.source_root.writeFile(.{ .sub_path = "file.md", .data = "{}<dep pattern=\"dep*\"/>" });
    try test_run_loop.loopOnce();
    try expectFile(site.output_root, "file.html", "\n");

    try site.source_root.writeFile(.{ .sub_path = "dep.md", .data = "{ hi: 5 }<xml/>" });
    try test_run_loop.loopOnce();
    try expectFile(site.output_root, "dep.html", "<xml/>\n");
    try expectFile(site.output_root, "file.html", "{ hi: 5 }\n");
}

test "remove a file => jay updates its dependents" {
    var test_run_loop = try TestRunLoop.init(.{ .markdown_patterns = &.{"*.md"} });
    defer test_run_loop.deinit();
    const site = test_run_loop.test_site.site;

    try site.source_root.writeFile(.{ .sub_path = "dep.md", .data = "{ hi: 4 }<html/>" });
    try site.source_root.writeFile(.{ .sub_path = "file.md", .data = "{}<dep pattern=\"dep*\"/>" });
    try test_run_loop.loopOnce();
    try expectFile(site.output_root, "dep.html", "<html/>\n");
    try expectFile(site.output_root, "file.html", "{ hi: 4 }\n");

    try site.source_root.deleteFile("dep.md");
    try test_run_loop.loopOnce();
    try expectNoFile(site.output_root, "dep.html");
    try expectFile(site.output_root, "file.html", "\n");
}

test "add a markdown file with metadata => jay removes the metadata from output contents" {
    var test_run_loop = try TestRunLoop.init(.{ .markdown_patterns = &.{"*.md"} });
    defer test_run_loop.deinit();
    const site = test_run_loop.test_site.site;

    try site.source_root.writeFile(.{ .sub_path = "file.md", .data = "{ hi: 4 }<html/>" });
    try test_run_loop.loopOnce();
    try expectFile(site.output_root, "file.html", "<html/>\n");
}

test "add a non-markdown file starting with a '{' char => jay does not process the metadata" {
    var test_run_loop = try TestRunLoop.init(.{ .static_patterns = &.{""} });
    defer test_run_loop.deinit();
    const site = test_run_loop.test_site.site;

    try site.source_root.writeFile(.{ .sub_path = "file.md", .data = "{ <html/>" });
    try test_run_loop.loopOnce();
    try expectFile(site.output_root, "file.md", "{ <html/>");
}

test "change a file but not its metadata => jay updates the file" {
    var test_run_loop = try TestRunLoop.init(.{ .markdown_patterns = &.{"*.md"} });
    defer test_run_loop.deinit();
    const site = test_run_loop.test_site.site;

    try site.source_root.writeFile(.{ .sub_path = "file.md", .data = "{ hi: 4 }<html/>" });
    try test_run_loop.loopOnce();
    try expectFile(site.output_root, "file.html", "<html/>\n");

    try site.source_root.writeFile(.{ .sub_path = "file.md", .data = "{ hi: 4 }<xml/>" });
    try test_run_loop.loopOnce();
    try expectFile(site.output_root, "file.html", "<xml/>\n");
}

test "add a file for a markdown rule without a markdown extension => jay shows an error" {
    var test_run_loop = try TestRunLoop.init(.{ .markdown_patterns = &.{"*"} });
    defer test_run_loop.deinit();
    const site = test_run_loop.test_site.site;

    try site.source_root.writeFile(.{ .sub_path = "file.txt", .data = "{}<html/>" });
    try test_run_loop.loopOnce();
    try expectFile(site.output_root, "file.html", "<html/>\n");
    try std.testing.expectEqualStrings(
        \\One of the pages for a markdown rule does not have a
        \\markdown extension:
        \\
        \\  file.txt
        \\
        \\Maybe the file is in the wrong directory? If it really
        \\contains markdown, consider renaming the file to:
        \\
        \\  file.md
        \\
    , test_run_loop.output());

    // Rename the file to have a .md extension => jay marks the problem fixed.
    try site.source_root.rename("file.txt", "file.md");
    try test_run_loop.loopOnce();
    try std.testing.expectEqualStrings("", test_run_loop.output());
}

test "markdown file contains invalid metadata => jay shows an error" {
    var test_run_loop = try TestRunLoop.init(.{ .markdown_patterns = &.{"*.md"} });
    defer test_run_loop.deinit();
    var site = test_run_loop.test_site.site;

    try site.source_root.writeFile(.{ .sub_path = "file.md", .data = "{<html/>" });
    try test_run_loop.loopOnce();
    try std.testing.expectEqualStrings(
        \\There's something wrong with the frontmatter at the top
        \\of this markdown file:
        \\
        \\  file.md
        \\
        \\I believe there's a frontmatter there because the file
        \\starts with a '{' character, but can't read the rest.
        \\I'm expecting a valid Roc record.
        \\
        \\Tip: Copy the frontmatter into `roc repl` to validate it.
        \\
    , test_run_loop.output());

    // Fix the frontmatter => Jay removes the error
    try site.source_root.writeFile(.{ .sub_path = "file.md", .data = "{}<html/>" });
    try test_run_loop.loopOnce();
    try std.testing.expectEqualStrings("", test_run_loop.output());
}

test "add an untypical file type => jay shows an error" {
    var test_run_loop = try TestRunLoop.init(.{ .markdown_patterns = &.{"*"} });
    defer test_run_loop.deinit();
    var site = test_run_loop.test_site.site;
    const watcher = test_run_loop.watcher;

    // Create a FIFO (named pipe). We could create a number of esoteric POSIX
    // files here, just picking FIFO because it's relatively easy.
    std.debug.assert(0 == std.os.linux.mknodat(
        site.source_root.fd,
        "file",
        std.os.linux.S.IFIFO | std.os.linux.S.IRWXU,
        0,
    ));

    // Perform the initial scan => Jay reports an error
    try scanRecursively(std.testing.allocator, site, watcher, "");
    try test_run_loop.loopOnce();
    try std.testing.expectEqualStrings(
        \\I came across a source file with type 'named_pipe':
        \\
        \\  file
        \\
        \\I don't support files of type 'named_pipe'. Please remove it, or
        \\add an ignore pattern for it.
        \\
    , test_run_loop.output());

    // Remove the file => Jay removes the error
    try site.source_root.deleteFile("file");
    try test_run_loop.loopOnce();
    try std.testing.expectEqualStrings("", test_run_loop.output());

    // Add the file and let the watcher find it => Hay reports the error again
    std.debug.assert(0 == std.os.linux.mknodat(
        site.source_root.fd,
        "file",
        std.os.linux.S.IFIFO | std.os.linux.S.IRWXU,
        0,
    ));
    try test_run_loop.loopOnce();
    try std.testing.expectEqualStrings(
        \\I came across a source file with type 'named_pipe':
        \\
        \\  file
        \\
        \\I don't support files of type 'named_pipe'. Please remove it, or
        \\add an ignore pattern for it.
        \\
    , test_run_loop.output());
}

test "add a symlink to a directory => jay treats it as a regular directory" {
    var tmpdir = std.testing.tmpDir(.{});
    defer tmpdir.cleanup();
    try tmpdir.dir.writeFile(.{ .sub_path = "file.md", .data = "{}<html/>" });

    var test_run_loop = try TestRunLoop.init(.{ .markdown_patterns = &.{"linked/*"} });
    defer test_run_loop.deinit();
    var site = test_run_loop.test_site.site;
    const watcher = test_run_loop.watcher;

    var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const link_target = try std.fmt.bufPrint(&buf, "../{s}", .{tmpdir.sub_path});
    try site.source_root.symLink(link_target, "linked", .{ .is_directory = true });

    // Perform the initial scan => Jay scans the symlinked directory
    try scanRecursively(std.testing.allocator, site, watcher, "");
    try test_run_loop.loopOnce();
    try std.testing.expectEqualStrings("", test_run_loop.output());
    try expectFile(site.output_root, "linked/file.html", "<html/>\n");

    // Change source file in symlinked directory => Jay regenerates the output file
    try tmpdir.dir.writeFile(.{ .sub_path = "file.md", .data = "{}<span/>" });
    try test_run_loop.loopOnce();
    try std.testing.expectEqualStrings("", test_run_loop.output());
    try expectFile(site.output_root, "linked/file.html", "<span/>\n");

    // Delete symlink => Jay deletes outputs for source files in symlinked directory
    try site.source_root.deleteFile("linked");
    try test_run_loop.loopOnce();
    try std.testing.expectEqualStrings("", test_run_loop.output());
    try expectNoFile(site.output_root, "linked/file.html");
}

test "add a symlink to a file => jay shows an error" {
    var tmpdir = std.testing.tmpDir(.{});
    defer tmpdir.cleanup();
    try tmpdir.dir.writeFile(.{ .sub_path = "file.md", .data = "{}<html/>" });

    var test_run_loop = try TestRunLoop.init(.{ .markdown_patterns = &.{"*"} });
    defer test_run_loop.deinit();
    var site = test_run_loop.test_site.site;
    const watcher = test_run_loop.watcher;

    var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const link_target = try std.fmt.bufPrint(&buf, "../{s}/file.md", .{tmpdir.sub_path});
    try site.source_root.symLink(link_target, "file.md", .{ .is_directory = false });

    // Perform the initial scan => Jay scans the symlinked file
    try scanRecursively(std.testing.allocator, site, watcher, "");
    try test_run_loop.loopOnce();
    try std.testing.expectEqualStrings(
        \\The following source file is a symlink:
        \\
        \\    file.md
        \\
        \\I don't currently support symlinks to individual source
        \\files. If this functionality is important to you, I'd
        \\love to hear about your usecase. Please create an issue
        \\at https://github.com/jwoudenberg/jay. Thank you!
        \\
        \\Tip: I do support symlinks to directories, maybe that
        \\     works as an alternative!
        \\
    , test_run_loop.output());
    try expectNoFile(site.output_root, "file.html");

    // Remove the symlink => Jay stops showing the error
    try site.source_root.deleteFile("file.md");
    try test_run_loop.loopOnce();
    try std.testing.expectEqualStrings("", test_run_loop.output());
}

test "replace source file path with a directory => jay removes output for source file" {
    var test_run_loop = try TestRunLoop.init(.{ .markdown_patterns = &.{"*.md"} });
    defer test_run_loop.deinit();
    var site = test_run_loop.test_site.site;

    try site.source_root.writeFile(.{ .sub_path = "file.md", .data = "{}<html/>" });
    try test_run_loop.loopOnce();
    try std.testing.expectEqualStrings("", test_run_loop.output());
    try expectFile(site.output_root, "file.html", "<html/>\n");

    try site.source_root.deleteFile("file.md");
    try site.source_root.makePath("file.md");
    try test_run_loop.loopOnce();
    try std.testing.expectEqualStrings("", test_run_loop.output());
    try expectNoFile(site.output_root, "file.html");
}

test "replace source directory path with a file => jay removes outputs for directory contents" {
    var test_run_loop = try TestRunLoop.init(.{ .static_patterns = &.{"bird"} });
    defer test_run_loop.deinit();
    var extern_dir = std.testing.tmpDir(.{});
    defer extern_dir.cleanup();
    var site = test_run_loop.test_site.site;

    try site.source_root.makePath("bird");
    try site.source_root.writeFile(.{ .sub_path = "bird/jay.html", .data = "<html/>" });
    try test_run_loop.loopOnce();
    try std.testing.expectEqualStrings("", test_run_loop.output());
    try expectFile(site.output_root, "bird/jay.html", "<html/>");

    try std.fs.rename(site.source_root, "bird", extern_dir.dir, "bird");
    try site.source_root.writeFile(.{ .sub_path = "bird", .data = "<span/>" });
    try test_run_loop.loopOnce();
    try std.testing.expectEqualStrings("", test_run_loop.output());
    try expectFile(site.output_root, "bird", "<span/>");
    try expectNoFile(site.output_root, "bird/jay.html");
}

test "add a source file the current user cannot read => jay shows an error" {
    var test_run_loop = try TestRunLoop.init(.{ .markdown_patterns = &.{"*.md"} });
    defer test_run_loop.deinit();
    var site = test_run_loop.test_site.site;

    try site.source_root.writeFile(.{
        .sub_path = "file.md",
        .data = "{}<html/>",
        .flags = .{ .mode = 0 },
    });
    try test_run_loop.loopOnce();
    try std.testing.expectEqualStrings(
        \\I don't have permission to read the following source path:
        \\
        \\    file.md
        \\
        \\Change permissions of the file so I can read it, or add
        \\an ignore pattern for this file.
        \\
    , test_run_loop.output());
    try expectNoFile(site.output_root, "file.html");

    //Change file permissions to allow read access => jay stops showing error
    try std.posix.fchmodat(site.source_root.fd, "file.md", std.os.linux.S.IRUSR, 0);
    try test_run_loop.loopOnce();
    try std.testing.expectEqualStrings("", test_run_loop.output());
    try expectFile(site.output_root, "file.html", "<html/>\n");
}

test "add a file that depends on itself => jay is okay with it" {
    var test_run_loop = try TestRunLoop.init(.{ .markdown_patterns = &.{"*.md"} });
    defer test_run_loop.deinit();
    const site = test_run_loop.test_site.site;

    try site.source_root.writeFile(.{ .sub_path = "file.md", .data = "{ hi: 4 }<dep pattern=\"*\"/>" });
    try test_run_loop.loopOnce();
    try expectFile(site.output_root, "file.html", "{ hi: 4 }\n");

    try site.source_root.writeFile(.{ .sub_path = "file.md", .data = "{ hi: 5 }<dep pattern=\"*\"/>" });
    try test_run_loop.loopOnce();
    try expectFile(site.output_root, "file.html", "{ hi: 5 }\n");
}

// -- test helpers --

fn expectFile(dir: std.fs.Dir, path: []const u8, expected: []const u8) !void {
    var buf: [1024]u8 = undefined;
    const contents = try dir.readFile(path, &buf);
    try std.testing.expectEqualStrings(expected, contents);
}

fn expectNoFile(dir: std.fs.Dir, path: []const u8) !void {
    _ = dir.statFile(path) catch |err| {
        if (err == error.FileNotFound) return else return err;
    };
    try std.testing.expect(false);
}

const TestRunLoop = struct {
    const TestSite = @import("site.zig").TestSite;

    allocator: std.mem.Allocator,
    source_root: std.fs.Dir,
    test_site: *TestSite,
    watcher: *Watcher,
    run_loop: *RunLoop,
    error_buf: std.BoundedArray(u8, 1024),

    fn init(config: TestSite.Config) !TestRunLoop {
        const allocator = std.testing.allocator;
        const test_site = try allocator.create(TestSite);
        test_site.* = try TestSite.init(config);
        const watcher = try allocator.create(Watcher);
        const source_root = try test_site.site.openSourceRoot(.{});
        watcher.* = try Watcher.init(allocator, source_root);
        const run_loop = try allocator.create(RunLoop);
        run_loop.* = try RunLoop.init(allocator, test_site.site, watcher, false);
        return .{
            .allocator = allocator,
            .source_root = source_root,
            .test_site = test_site,
            .watcher = watcher,
            .run_loop = run_loop,
            .error_buf = try std.BoundedArray(u8, 1024).init(0),
        };
    }

    fn deinit(self: *TestRunLoop) void {
        self.watcher.deinit();
        self.test_site.deinit();
        self.source_root.close();
        self.allocator.destroy(self.watcher);
        self.allocator.destroy(self.run_loop);
        self.allocator.destroy(self.test_site);
    }

    fn loopOnce(self: *TestRunLoop) !void {
        self.error_buf.len = 0;
        try self.run_loop.loopOnce(self.error_buf.writer());
    }

    fn output(self: *TestRunLoop) []const u8 {
        const clearScreenEscape = "\x1b[2J";
        const slice = self.error_buf.constSlice();
        if (std.mem.startsWith(u8, slice, clearScreenEscape)) {
            return slice[clearScreenEscape.len..];
        } else {
            return slice;
        }
    }
};
