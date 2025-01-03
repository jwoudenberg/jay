// Module responsible for producing the output files making up the static site.

const std = @import("std");
const Site = @import("site.zig").Site;
const RocList = @import("roc/list.zig").RocList;
const RocStr = @import("roc/str.zig").RocStr;
const platform = @import("platform.zig").platform;
const markdown = @import("markdown.zig");
const xml = @import("xml.zig");

pub fn generate(
    site: *Site,
    page: *Site.Page,
) !void {
    const arena = site.tmp_arena_state.allocator();
    const scanned = page.scanned orelse return;
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

            var output_writer = try OutputWriter.init(site, page);
            defer output_writer.deinit();

            try fifo.pump(source.reader(), output_writer.writer());
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

            var output_writer = try OutputWriter.init(site, page);
            defer output_writer.deinit();

            try platform.runPipeline(
                arena,
                site,
                page,
                tags,
                source,
                output_writer.writer(),
            );
        },
        .markdown => {
            // TODO: figure out what to do with files larger than this.
            const raw_source = site.source_root.readFileAlloc(
                arena,
                page.source_path.bytes(),
                1024 * 1024,
            ) catch |err| if (err == error.FileNotFound) return else return err;
            const markdown_bytes = if (scanned.frontmatter) |frontmatter|
                raw_source[frontmatter.len..]
            else
                raw_source;
            var html = try std.ArrayList(u8).initCapacity(arena, 1024 * 1024);
            try markdown.toHtml(&site.highlighter, html.writer(), markdown_bytes);
            const source = html.items;
            var replace_tags = try arena.alloc([]const u8, page.replace_tags.len);
            for (page.replace_tags, 0..) |tag, index| replace_tags[index] = tag.bytes();
            // TODO: calculate tags while generating HTML from markdown.
            const tags = try xml.parse(arena, source, replace_tags);

            var output_writer = try OutputWriter.init(site, page);
            defer output_writer.deinit();

            try platform.runPipeline(
                arena,
                site,
                page,
                tags,
                source,
                output_writer.writer(),
            );
        },
    }
}

const OutputWriter = struct {
    page: *Site.Page,
    output: std.fs.File,
    counting_writer: std.io.CountingWriter(std.fs.File.Writer),

    fn init(site: *Site, page: *Site.Page) !OutputWriter {
        const scanned = page.scanned orelse return error.CantOutputUnscannedPage;
        const output_path_bytes = scanned.output_path.bytes();
        if (std.fs.path.dirname(output_path_bytes)) |dir| try site.output_root.makePath(dir);
        site.output_root.deleteDir(output_path_bytes) catch |err| switch (err) {
            error.NotDir,
            error.FileNotFound,
            => {},
            else => return err,
        };
        const output = try site.output_root.createFile(output_path_bytes, .{ .truncate = true });
        errdefer output.close();
        const counting_writer = std.io.countingWriter(output.writer());
        return .{
            .page = page,
            .output = output,
            .counting_writer = counting_writer,
        };
    }

    fn deinit(self: *OutputWriter) void {
        self.page.generated = .{
            .output_len = self.counting_writer.bytes_written,
        };
        defer self.output.close();
    }

    fn writer(self: *OutputWriter) std.io.CountingWriter(std.fs.File.Writer).Writer {
        return self.counting_writer.writer();
    }
};
