// Module responsible for producing the output files making up the static site.

const std = @import("std");
const Site = @import("site.zig").Site;
const RocList = @import("roc/list.zig").RocList;
const RocStr = @import("roc/str.zig").RocStr;
const platform = @import("platform.zig").platform;
const xml = @import("xml.zig");
const c = @cImport({
    @cInclude("cmark-gfm.h");
});

pub fn generate(
    arena: std.mem.Allocator,
    site: *Site,
    page: *Site.Page,
) !void {
    const output_path_bytes = page.output_path.bytes();
    if (std.fs.path.dirname(output_path_bytes)) |dir| try site.output_root.makePath(dir);
    const output = try site.output_root.createFile(output_path_bytes, .{ .truncate = true });
    defer output.close();
    var counting_writer = std.io.countingWriter(output.writer());
    var writer = counting_writer.writer();
    try writeFile(arena, &writer, site, page);
    page.output_len = counting_writer.bytes_written;
}

fn writeFile(
    arena: std.mem.Allocator,
    writer: anytype,
    site: *Site,
    page: *Site.Page,
) !void {
    switch (page.processing) {
        .none => {
            // I'd like to use the below, but get the following error when I do:
            //     hidden symbol `__dso_handle' isn't defined
            // try state.source_root.copyFile(source_path, output_root, output_path, .{});

            const buffer = try arena.alloc(u8, 1024);
            var fifo = std.fifo.LinearFifo(u8, .Slice).init(buffer);
            defer fifo.deinit();

            const source = site.source_root.openFile(page.source_path.bytes(), .{}) catch |err| {
                if (err == error.FileNotFound) return else return err;
            };
            defer source.close();
            try fifo.pump(source.reader(), writer);
        },
        .xml => {
            // TODO: figure out what to do with files larger than this.
            const source = site.source_root.readFileAlloc(
                arena,
                page.source_path.bytes(),
                1024 * 1024,
            ) catch |err| if (err == error.FileNotFound) return else return err;
            var replace_tags = try arena.alloc([]const u8, page.replace_tags.len);
            for (page.replace_tags, 0..) |tag, index| replace_tags[index] = tag.bytes();
            const tags = try xml.parse(arena, source, replace_tags);
            try platform.runPipeline(
                arena,
                site,
                page,
                tags,
                source,
                writer,
            );
        },
        .markdown => {
            // TODO: figure out what to do with files larger than this.
            const raw_source = try site.source_root.readFileAlloc(
                arena,
                page.source_path.bytes(),
                1024 * 1024,
            );
            const markdown = raw_source[page.frontmatter.len..];
            const html = c.cmark_markdown_to_html(
                @ptrCast(markdown),
                markdown.len,
                c.CMARK_OPT_DEFAULT | c.CMARK_OPT_UNSAFE,
            ) orelse return error.OutOfMemory;
            defer std.c.free(html);
            const source = std.mem.span(html);
            var replace_tags = try arena.alloc([]const u8, page.replace_tags.len);
            for (page.replace_tags, 0..) |tag, index| replace_tags[index] = tag.bytes();
            const tags = try xml.parse(arena, source, replace_tags);
            try platform.runPipeline(
                arena,
                site,
                page,
                tags,
                source,
                writer,
            );
        },
    }
}
