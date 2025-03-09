// Partial XML parsing. This is not a general-purpose XML parsing, nor
// intending to be.
//
// Our requirements for XML parsing are that we can identify the location of
// tags that the application author is targetting for replacement. We need the
// attributes of those tags and the location of their contents.
//
// TODO: Show the user pretty XML parsing errors.

const std = @import("std");

pub const Tag = struct {
    name: []const u8,
    index: usize, // which tag was matched. Index into tag_names array passed in.
    attributes: []const u8, // slice contains all the tags attributes.
    outer_start: usize, // index of the '<' byte of the opening tag in the source.
    outer_end: usize, // length from the open tag '<' to the closing tag '>'.
    inner_start: usize, // length of the open tag.
    inner_end: usize, // length of the slice between the open and close tags.
};

pub fn parse(
    allocator: std.mem.Allocator,
    document: []const u8,
    tag_names: []const []const u8,
) ![]const Tag {
    var chunks = std.ArrayList(Tag).init(allocator);
    defer chunks.deinit();
    var stack = std.ArrayList(Tag).init(allocator);
    defer stack.deinit();
    var index: usize = 0;
    while (index < document.len) {
        index = std.mem.indexOfScalarPos(u8, document, index, '<') orelse break;
        switch (document[index + 1]) {
            '!' => {
                // This is a doctype definition.
                index = std.mem.indexOfScalarPos(
                    u8,
                    document,
                    index + 1,
                    '>',
                ) orelse return error.CantFindEndOfDoctype;
                index += 1;
            },
            '/' => {
                // This is a closing tag.
                const name_end = std.mem.indexOfAnyPos(u8, document, index + 1, " \t\n\r>") orelse return error.CantFindCloseTagNameEnd;
                const name = document[2 + index .. name_end];
                const tag_end = std.mem.indexOfScalarPos(u8, document, name_end, '>') orelse return error.CantFindCloseTagEnd;
                var tag = stack.pop() orelse return error.FoundCloseTagsWhenNoTagsWereOpen;
                if (!std.mem.eql(u8, tag.name, name)) return error.MismatchedCloseAndOpenTags;

                if (index_of(tag_names, name)) |tag_index| {
                    tag.index = tag_index;
                    tag.outer_end = 1 + tag_end;
                    tag.inner_end = index;
                    try chunks.append(tag);
                }

                index = tag_end + 1;
            },
            else => {
                // This is an opening tag.
                const name_end = std.mem.indexOfAnyPos(u8, document, index + 1, " \t\n\r/>") orelse return error.CantFindTagNameEnd;
                const name = document[1 + index .. name_end];

                var attr_end = std.mem.indexOfScalarPos(u8, document, name_end, '>') orelse return error.CantFindTagEnd;
                var is_self_closing = false;
                if (document[attr_end - 1] == '/') {
                    is_self_closing = true;
                    attr_end -= 1;
                }
                const attributes = document[name_end..attr_end];

                if (is_self_closing) {
                    if (index_of(tag_names, name)) |tag_index| {
                        try chunks.append(.{
                            .name = name,
                            .index = tag_index,
                            .attributes = attributes,
                            .outer_start = index,
                            .inner_start = 2 + attr_end,
                            .outer_end = 2 + attr_end,
                            .inner_end = 2 + attr_end,
                        });
                    }
                    index = attr_end + 2;
                } else {
                    try stack.append(.{
                        .name = name,
                        .attributes = attributes,
                        .outer_start = index,
                        .inner_start = 1 + attr_end,
                        // We'll set these properlies when we reach the close tag.
                        .index = undefined,
                        .outer_end = undefined,
                        .inner_end = undefined,
                    });
                    index = attr_end + 1;
                }
            },
        }
    }

    return chunks.toOwnedSlice();
}

test "parse: single tag" {
    const tags = try parse(std.testing.allocator, "<tag attr='4'>hi</tag>", &[_][]const u8{"tag"});
    defer std.testing.allocator.free(tags);
    try std.testing.expectEqual(1, tags.len);
    try std.testing.expectEqualDeep(Tag{
        .index = 0,
        .name = "tag",
        .attributes = " attr='4'",
        .outer_start = 0,
        .outer_end = 22,
        .inner_start = 14,
        .inner_end = 16,
    }, tags[0]);
}

test "parse: attribute with slash" {
    const tags = try parse(std.testing.allocator, "<tag x='dir/' y=\"/txt\"></tag>", &[_][]const u8{"tag"});
    defer std.testing.allocator.free(tags);
    try std.testing.expectEqual(1, tags.len);
    try std.testing.expectEqualDeep(Tag{
        .index = 0,
        .name = "tag",
        .attributes = " x='dir/' y=\"/txt\"",
        .outer_start = 0,
        .outer_end = 29,
        .inner_start = 23,
        .inner_end = 23,
    }, tags[0]);
}

test "parse: nested tags" {
    const tags = try parse(
        std.testing.allocator,
        "<tag>hi <inner1/> <inner2/> </tag>",
        &[_][]const u8{ "tag", "inner2" },
    );
    defer std.testing.allocator.free(tags);
    try std.testing.expectEqual(2, tags.len);
    try std.testing.expectEqualDeep(Tag{
        .index = 1,
        .name = "inner2",
        .attributes = "",
        .outer_start = 18,
        .outer_end = 27,
        .inner_start = 27,
        .inner_end = 27,
    }, tags[0]);
    try std.testing.expectEqualDeep(Tag{
        .index = 0,
        .name = "tag",
        .attributes = "",
        .outer_start = 0,
        .outer_end = 34,
        .inner_start = 5,
        .inner_end = 28,
    }, tags[1]);
}

test "parse: self-closing tag" {
    const tags = try parse(std.testing.allocator, "<tag attr='4' />", &[_][]const u8{"tag"});
    defer std.testing.allocator.free(tags);
    try std.testing.expectEqual(1, tags.len);
    try std.testing.expectEqualDeep(Tag{
        .index = 0,
        .name = "tag",
        .attributes = " attr='4' ",
        .outer_start = 0,
        .outer_end = 16,
        .inner_start = 16,
        .inner_end = 16,
    }, tags[0]);
}

test "parse: ignores doctype" {
    const tags = try parse(std.testing.allocator, "<!doctype html><html/>", &[_][]const u8{"html"});
    defer std.testing.allocator.free(tags);
    try std.testing.expectEqual(1, tags.len);
    try std.testing.expectEqualDeep(Tag{
        .index = 0,
        .name = "html",
        .attributes = "",
        .outer_start = 15,
        .outer_end = 22,
        .inner_start = 22,
        .inner_end = 22,
    }, tags[0]);
}

fn index_of(haystack: []const []const u8, needle: []const u8) ?usize {
    for (haystack, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate, needle)) return index;
    }
    return null;
}

pub fn writeEscaped(writer: anytype, text: []const u8) !void {
    var offset: usize = 0;
    while (std.mem.indexOfAnyPos(u8, text, offset, "<&")) |index| {
        try writer.writeAll(text[offset..index]);
        switch (text[index]) {
            '<' => try writer.writeAll("&lt;"),
            '&' => try writer.writeAll("&amp;"),
            else => return error.XmlUnexpectedEscapeChar,
        }
        offset = index + 1;
    }
    try writer.writeAll(text[offset..]);
}

test writeEscaped {
    var buf = try std.BoundedArray(u8, 128).init(0);

    try writeEscaped(testWriter(&buf), "text");
    try std.testing.expectEqualStrings("text", buf.slice());

    try writeEscaped(testWriter(&buf), "<text");
    try std.testing.expectEqualStrings("&lt;text", buf.slice());

    try writeEscaped(testWriter(&buf), "&text");
    try std.testing.expectEqualStrings("&amp;text", buf.slice());

    try writeEscaped(testWriter(&buf), "text<");
    try std.testing.expectEqualStrings("text&lt;", buf.slice());

    try writeEscaped(testWriter(&buf), "hi<&ho");
    try std.testing.expectEqualStrings("hi&lt;&amp;ho", buf.slice());
}

// This function will write an html foo="bar" attribute.
// The caller is expected to unsure no invalid characters are passed for the
// key. The value argument is escaped.
pub fn writeAttribute(writer: anytype, key: []const u8, value: []const u8) !void {
    try writer.writeAll(key);
    try writer.writeAll("=\"");
    var offset: usize = 0;
    while (std.mem.indexOfAnyPos(u8, value, offset, "<&\"")) |index| {
        try writer.writeAll(value[offset..index]);
        switch (value[index]) {
            '<' => try writer.writeAll("&lt;"),
            '&' => try writer.writeAll("&amp;"),
            '"' => try writer.writeAll("&quot;"),
            else => return error.XmlUnexpectedAttributeEscapeChar,
        }
        offset = index + 1;
    }
    try writer.writeAll(value[offset..]);
    try writer.writeAll("\"");
}

test writeAttribute {
    var buf = try std.BoundedArray(u8, 128).init(0);

    try writeAttribute(testWriter(&buf), "greet", "hi");
    try std.testing.expectEqualStrings("greet=\"hi\"", buf.slice());

    try writeAttribute(testWriter(&buf), "greet", "<hi");
    try std.testing.expectEqualStrings("greet=\"&lt;hi\"", buf.slice());

    try writeAttribute(testWriter(&buf), "greet", "&hi");
    try std.testing.expectEqualStrings("greet=\"&amp;hi\"", buf.slice());

    try writeAttribute(testWriter(&buf), "greet", "\"hi");
    try std.testing.expectEqualStrings("greet=\"&quot;hi\"", buf.slice());

    try writeAttribute(testWriter(&buf), "greet", "hi<");
    try std.testing.expectEqualStrings("greet=\"hi&lt;\"", buf.slice());

    try writeAttribute(testWriter(&buf), "greet", "hi<&ho");
    try std.testing.expectEqualStrings("greet=\"hi&lt;&amp;ho\"", buf.slice());
}

fn testWriter(buf: *std.BoundedArray(u8, 128)) std.BoundedArray(u8, 128).Writer {
    buf.len = 0;
    return buf.writer();
}
