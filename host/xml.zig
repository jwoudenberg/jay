const std = @import("std");

pub const Tag = struct {
    name: []const u8, // slice containing the tags' name.
    attributes: []const u8, // slice contains all the tags attributes.
    offset: usize, // index of the '<' byte of the opening tag in the source.
    outer_len: usize, // length from the open tag '<' to the closing tag '>'.
    open_tag_len: usize, // length of the open tag.
    content_len: usize, // length of the slice between the open and close tags.
};

// This is not a general-purpose XML parsing, nor intending to be.
//
// Our requirements for XML parsing are that we can identify the location of
// tags that the application author is targetting for replacement. We need the
// attributes of those tags and the location of their contents.
//
// TODO: Show the user pretty XML parsing errors.
pub fn parse(
    allocator: std.mem.Allocator,
    document: []const u8,
    tag_names: []const []const u8,
) ![]const Tag {
    var chunks = std.ArrayList(Tag).init(allocator);
    errdefer chunks.deinit();
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
                var tag = stack.popOrNull() orelse return error.FoundCloseTagsWhenNoTagsWereOpen;
                if (!std.mem.eql(u8, tag.name, name)) return error.MismatchedCloseAndOpenTags;

                if (contains(tag_names, name)) {
                    tag.outer_len = 1 + tag_end - tag.offset;
                    tag.content_len = index - tag.offset - tag.open_tag_len;
                    try chunks.append(tag);
                }

                index = tag_end + 1;
            },
            else => {
                // This is an opening tag.
                const name_end = std.mem.indexOfAnyPos(u8, document, index + 1, " \t\n\r/>") orelse return error.CantFindTagNameEnd;
                const name = document[1 + index .. name_end];

                const attr_end = std.mem.indexOfAnyPos(u8, document, name_end, "/>") orelse return error.CantFindTagEnd;
                const attributes = document[name_end..attr_end];

                if (document[attr_end] == '/') {
                    if (contains(tag_names, name)) {
                        try chunks.append(.{
                            .name = name,
                            .attributes = attributes,
                            .offset = index,
                            .open_tag_len = 2 + attr_end - index,
                            .content_len = 0,
                            .outer_len = 2 + attr_end - index,
                        });
                    }
                    index = attr_end + 2;
                } else {
                    try stack.append(.{
                        .name = name,
                        .attributes = attributes,
                        .offset = index,
                        .open_tag_len = 1 + attr_end - index,
                        // We'll set these properlies when we reach the close tag.
                        .outer_len = 0,
                        .content_len = 0,
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
        .name = "tag",
        .attributes = " attr='4'",
        .offset = 0,
        .outer_len = 22,
        .open_tag_len = 14,
        .content_len = 2,
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
        .name = "inner2",
        .attributes = "",
        .offset = 18,
        .outer_len = 9,
        .open_tag_len = 9,
        .content_len = 0,
    }, tags[0]);
    try std.testing.expectEqualDeep(Tag{
        .name = "tag",
        .attributes = "",
        .offset = 0,
        .outer_len = 34,
        .open_tag_len = 5,
        .content_len = 23,
    }, tags[1]);
}

test "parse: self-closing tag" {
    const tags = try parse(std.testing.allocator, "<tag attr='4' />", &[_][]const u8{"tag"});
    defer std.testing.allocator.free(tags);
    try std.testing.expectEqual(1, tags.len);
    try std.testing.expectEqualDeep(Tag{
        .name = "tag",
        .attributes = " attr='4' ",
        .offset = 0,
        .outer_len = 16,
        .open_tag_len = 16,
        .content_len = 0,
    }, tags[0]);
}

test "parse: ignores doctype" {
    const tags = try parse(std.testing.allocator, "<!doctype html><html/>", &[_][]const u8{"html"});
    defer std.testing.allocator.free(tags);
    try std.testing.expectEqual(1, tags.len);
    try std.testing.expectEqualDeep(Tag{
        .name = "html",
        .attributes = "",
        .offset = 15,
        .outer_len = 7,
        .open_tag_len = 7,
        .content_len = 0,
    }, tags[0]);
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |candidate| {
        if (std.mem.eql(u8, candidate, needle)) return true;
    }
    return false;
}
