// Module responsible for producing the output files making up the static site.

const std = @import("std");
const Site = @import("site.zig").Site;
const RocList = @import("roc/list.zig").RocList;
const RocStr = @import("roc/str.zig").RocStr;
const platform = @import("platform.zig");
const xml = @import("xml.zig");
const util = @import("util.zig");
const c = @cImport({
    @cInclude("cmark-gfm.h");
});

pub fn generate(
    gpa: std.mem.Allocator,
    site: *const Site,
    output_dir_path: []const u8,
) !void {
    // Clear output directory if it already exists.
    site.source_root.deleteTree(output_dir_path) catch |err| {
        if (err != error.NotDir) {
            return err;
        }
    };
    try site.source_root.makeDir(output_dir_path);
    var output_dir = try site.source_root.openDir(output_dir_path, .{});
    defer output_dir.close();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    for (site.pages.items) |page| {
        if (std.fs.path.dirname(page.output_path[1..])) |dir| try output_dir.makePath(dir);
        const rule = site.rules[page.rule_index];
        try generateSitePath(
            arena_state.allocator(),
            site.source_root,
            rule,
            page,
            output_dir,
        );
        _ = arena_state.reset(.retain_capacity);
    }
}

fn generateSitePath(
    arena: std.mem.Allocator,
    source_root: std.fs.Dir,
    rule: Site.Rule,
    page: Site.Page,
    output_dir: std.fs.Dir,
) !void {
    const output = try output_dir.createFile(page.output_path[1..], .{ .truncate = true, .exclusive = true });
    defer output.close();
    var writer = output.writer();

    switch (rule.processing) {
        .ignore => return error.UnexpectedlyAskedToGenerateOutputForIgnoredFile,
        .bootstrap => return error.UnexpectedlyAskedToGenerateOutputForBootstrapRule,
        .none => {
            // I'd like to use the below, but get the following error when I do:
            //     hidden symbol `__dso_handle' isn't defined
            // try state.source_root.copyFile(source_path, output_dir, output_path, .{});

            const buffer = try arena.alloc(u8, 1024);
            var fifo = std.fifo.LinearFifo(u8, .Slice).init(buffer);
            defer fifo.deinit();

            const source = try source_root.openFile(page.source_path, .{});
            defer source.close();
            try fifo.pump(source.reader(), output.writer());
        },
        .xml => {
            // TODO: figure out what to do with files larger than this.
            const source = try source_root.readFileAlloc(arena, page.source_path, 1024 * 1024);
            const contents = try runPageTransforms(arena, source, rule, page);
            try writeRocContents(contents, source, &writer);
        },
        .markdown => {
            // TODO: figure out what to do with files larger than this.
            const raw_source = try source_root.readFileAlloc(
                arena,
                page.source_path,
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
            const contents = try runPageTransforms(
                arena,
                source,
                rule,
                page,
            );
            try writeRocContents(contents, source, &writer);
        },
    }
}

fn runPageTransforms(
    arena: std.mem.Allocator,
    source: []const u8,
    rule: Site.Rule,
    page: Site.Page,
) !RocList {
    const tags = try xml.parse(arena, source, rule.replaceTags);
    var roc_tags = std.ArrayList(platform.Tag).init(arena);
    for (tags) |tag| {
        try roc_tags.append(platform.Tag{
            .attributes = RocList.fromSlice(u8, tag.attributes, false),
            .outerStart = @as(u32, @intCast(tag.outer_start)),
            .outerEnd = @as(u32, @intCast(tag.outer_end)),
            .innerStart = @as(u32, @intCast(tag.inner_start)),
            .innerEnd = @as(u32, @intCast(tag.inner_end)),
            .index = @as(u32, @intCast(tag.index)),
        });
    }
    const roc_page = platform.Page{
        .meta = RocList.fromSlice(u8, page.frontmatter, false),
        .path = RocStr.fromSlice(util.formatPathForPlatform(page.output_path)),
        .ruleIndex = @as(u32, @intCast(page.rule_index)),
        .tags = RocList.fromSlice(platform.Tag, try roc_tags.toOwnedSlice(), true),
        .len = @as(u32, @intCast(source.len)),
    };
    var contents = RocList.empty();
    platform.roc__runPipelineForHost_1_exposed_generic(&contents, &roc_page);
    return contents;
}

fn writeRocContents(
    contents: RocList,
    source: []const u8,
    writer: *std.fs.File.Writer,
) !void {
    var roc_xml_iterator = RocListIterator(platform.Slice).init(contents);
    while (roc_xml_iterator.next()) |roc_slice| {
        switch (roc_slice.tag) {
            .from_source => {
                const slice = roc_slice.payload.from_source;
                try writer.writeAll(source[slice.start..slice.end]);
            },
            .roc_generated => {
                const roc_slice_list = roc_slice.payload.roc_generated;
                const len = roc_slice_list.len();
                if (len == 0) continue;
                const slice = roc_slice_list.elements(u8) orelse return error.RocListUnexpectedEmpty;
                try writer.writeAll(slice[0..len]);
            },
        }
    }
}

fn RocListIterator(comptime T: type) type {
    return struct {
        const Self = @This();

        elements: ?[*]T,
        len: usize,
        index: usize,

        fn init(list: RocList) Self {
            return Self{
                .elements = list.elements(T),
                .len = list.len(),
                .index = 0,
            };
        }

        fn next(self: *Self) ?T {
            if (self.index < self.len) {
                const elem = self.elements.?[self.index];
                self.index += 1;
                return elem;
            } else {
                return null;
            }
        }
    };
}
