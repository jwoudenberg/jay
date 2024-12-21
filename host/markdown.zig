const std = @import("std");
const xml = @import("xml.zig");
const c = @cImport({
    @cInclude("cmark-gfm.h");
    @cInclude("api.h");
    @cInclude("highlight.h");
});

pub fn toHtml(writer: anytype, markdown: []const u8) !void {
    // TODO: do streaming parsing to avoid allocating the entire markdown doc.
    const root_node = c.cmark_parse_document(
        @ptrCast(markdown),
        markdown.len,
        c.CMARK_OPT_DEFAULT | c.CMARK_OPT_UNSAFE,
    ) orelse return error.CmarkOutOfMemory;
    defer c.cmark_node_free(root_node);
    const iter = c.cmark_iter_new(root_node) orelse return error.CmarkOutOfMemory;
    defer c.cmark_iter_free(iter);

    while (true) {
        switch (c.cmark_iter_next(iter)) {
            c.CMARK_EVENT_DONE => break,
            c.CMARK_EVENT_ENTER => {
                const node = c.cmark_iter_get_node(iter) orelse return error.CmarkNodeMissing;
                try writeNode(writer, true, node);
            },
            c.CMARK_EVENT_EXIT => {
                const node = c.cmark_iter_get_node(iter) orelse return error.CmarkNodeMissing;
                try writeNode(writer, false, node);
            },
            else => |ev_type| {
                std.debug.print("unexpected cmark event: {}\n", .{ev_type});
                return error.CmarkUnexpectedEvent;
            },
        }
    }
}

test toHtml {
    var buf = try std.BoundedArray(u8, 128).init(0);

    try toHtml(testWriter(&buf), "# header");
    try std.testing.expectEqualStrings(
        "<h1>header</h1>",
        buf.slice(),
    );

    try toHtml(testWriter(&buf), "text & escaped");
    try std.testing.expectEqualStrings(
        "<p>text &amp; escaped</p>",
        buf.slice(),
    );

    try toHtml(testWriter(&buf), "**bold** and *cursed*");
    try std.testing.expectEqualStrings(
        "<p><strong>bold</strong> and <em>cursed</em></p>",
        buf.slice(),
    );

    try toHtml(testWriter(&buf), "learn [Roc](roc-lang.org)!");
    try std.testing.expectEqualStrings(
        "<p>learn <a href=\"roc-lang.org\">Roc</a>!</p>",
        buf.slice(),
    );

    try toHtml(testWriter(&buf), "look! ![eyes](eyes.png)");
    try std.testing.expectEqualStrings(
        "<p>look! <img src=\"eyes.png\" alt=\"eyes\" /></p>",
        buf.slice(),
    );

    try toHtml(testWriter(&buf), "look! ![eyes](eyes.png \"stare\")");
    try std.testing.expectEqualStrings(
        "<p>look! <img src=\"eyes.png\" alt=\"eyes\" title=\"stare\" /></p>",
        buf.slice(),
    );

    try toHtml(testWriter(&buf),
        \\Groceries:
        \\- Broccoli
        \\- Cashews
    );
    try std.testing.expectEqualStrings(
        "<p>Groceries:</p><ul><li>Broccoli</li><li>Cashews</li></ul>",
        buf.slice(),
    );

    try toHtml(testWriter(&buf),
        \\Steps:
        \\1. Look
        \\1. Cross
    );
    try std.testing.expectEqualStrings(
        "<p>Steps:</p><ol><li>Look</li><li>Cross</li></ol>",
        buf.slice(),
    );

    try toHtml(testWriter(&buf),
        \\Steps:
        \\
        \\2. Look
        \\3. Cross
    );
    try std.testing.expectEqualStrings(
        "<p>Steps:</p><ol start=\"2\"><li>Look</li><li>Cross</li></ol>",
        buf.slice(),
    );

    try toHtml(testWriter(&buf),
        \\Groceries:
        \\
        \\- multiple
        \\
        \\  paragraphs
    );
    try std.testing.expectEqualStrings(
        "<p>Groceries:</p><ul><li><p>multiple</p><p>paragraphs</p></li></ul>",
        buf.slice(),
    );

    try toHtml(testWriter(&buf),
        \\Before
        \\
        \\---
        \\
        \\After
    );
    try std.testing.expectEqualStrings(
        "<p>Before</p><hr/><p>After</p>",
        buf.slice(),
    );

    try toHtml(testWriter(&buf), "Example: `1 + 1`");
    try std.testing.expectEqualStrings(
        "<p>Example: <code>1 + 1</code></p>",
        buf.slice(),
    );

    try toHtml(testWriter(&buf),
        \\Example:
        \\
        \\```roc
        \\1 + 1
        \\```
    );
    try std.testing.expectEqualStrings(
        "<p>Example:</p><pre><code>1 + 1\n</code></pre>",
        buf.slice(),
    );

    try toHtml(testWriter(&buf),
        \\Widget:
        \\
        \\<my-greeter>**hi**</my-greeter>
    );
    try std.testing.expectEqualStrings(
        "<p>Widget:</p><p><my-greeter><strong>hi</strong></my-greeter></p>",
        buf.slice(),
    );

    try toHtml(testWriter(&buf),
        \\Html:
        \\
        \\<section><h2>Header!</h2></section>
    );
    try std.testing.expectEqualStrings(
        "<p>Html:</p><section><h2>Header!</h2></section>\n",
        buf.slice(),
    );
}

fn writeOpenTag(writer: anytype, tag: []const u8) !void {
    try writer.print("<{s}>", .{tag});
}

fn writeCloseTag(writer: anytype, tag: []const u8) !void {
    try writer.print("</{s}>", .{tag});
}

fn writeNode(
    writer: anytype,
    comptime open: bool,
    node: *c.cmark_node,
) !void {
    const writeTag = if (open) writeOpenTag else writeCloseTag;
    switch (c.cmark_node_get_type(node)) {
        c.CMARK_NODE_NONE => {
            return error.CmarkUnexpectedNodeNone;
        },
        c.CMARK_NODE_DOCUMENT => {
            // Don't generate an HTML wrapper around the document.
            // The user can add this if they want.
        },
        c.CMARK_NODE_BLOCK_QUOTE => {
            try writeTag(writer, "blockquote");
        },
        c.CMARK_NODE_LIST => {
            switch (c.cmark_node_get_list_type(node)) {
                c.CMARK_NO_LIST => return error.CmarkUnexpectedNoList,
                c.CMARK_BULLET_LIST => try writeTag(writer, "ul"),
                c.CMARK_ORDERED_LIST => {
                    const start = c.cmark_node_get_list_start(node);
                    if (start == 1) {
                        try writeTag(writer, "ol");
                    } else if (open) {
                        try writer.print("<ol start=\"{}\">", .{start});
                    } else {
                        try writer.writeAll("</ol>");
                    }
                },
                else => |list_type| {
                    std.debug.print("unexpected cmark list type: {}\n", .{list_type});
                    return error.CmarkUnexpectedListType;
                },
            }
        },
        c.CMARK_NODE_ITEM => {
            try writeTag(writer, "li");
        },
        c.CMARK_NODE_CODE_BLOCK => {
            const code = c.cmark_node_get_literal(node);
            try writer.writeAll("<pre><code>");
            try writer.writeAll(std.mem.span(code));
            try writer.writeAll("</code></pre>");
        },
        c.CMARK_NODE_HTML_BLOCK => {
            const html = c.cmark_node_get_literal(node);
            try writer.writeAll(std.mem.span(html));
        },
        c.CMARK_NODE_CUSTOM_BLOCK => {
            return error.CmarkUnexpectedCustomBlock;
        },
        c.CMARK_NODE_PARAGRAPH => {
            const parent = c.cmark_node_parent(node);
            const grand_parent = c.cmark_node_parent(parent);
            const tight = c.cmark_node_get_list_tight(grand_parent);
            if (tight == 0) try writeTag(writer, "p");
        },
        c.CMARK_NODE_HEADING => {
            const level = c.cmark_node_get_heading_level(node);
            if (level == 0) return error.CmarkUnexpectedMissingHeadingLevel;
            if (open) {
                try writer.print("<h{}>", .{level});
            } else {
                try writer.print("</h{}>", .{level});
            }
        },
        c.CMARK_NODE_THEMATIC_BREAK => {
            try writer.writeAll("<hr/>");
        },
        c.CMARK_NODE_FOOTNOTE_DEFINITION => {
            return error.CmarkFootnotesCurrentlyUnsupported;
        },
        c.CMARK_NODE_TEXT => {
            const text = c.cmark_node_get_literal(node);
            try xml.writeEscaped(writer, std.mem.span(text));
        },
        c.CMARK_NODE_CODE => {
            const text = c.cmark_node_get_literal(node);
            try writer.writeAll("<code>");
            try xml.writeEscaped(writer, std.mem.span(text));
            try writer.writeAll("</code>");
        },
        c.CMARK_NODE_HTML_INLINE => {
            const text = c.cmark_node_get_literal(node);
            try writer.writeAll(std.mem.span(text));
        },
        c.CMARK_NODE_SOFTBREAK,
        c.CMARK_NODE_LINEBREAK,
        => {
            try writer.writeAll(" ");
        },
        c.CMARK_NODE_CUSTOM_INLINE => {
            return error.CmarkUnexpectedCustomINLINE;
        },
        c.CMARK_NODE_EMPH => {
            try writeTag(writer, "em");
        },
        c.CMARK_NODE_STRONG => {
            try writeTag(writer, "strong");
        },
        c.CMARK_NODE_LINK => {
            if (open) {
                const url = c.cmark_node_get_url(node) orelse return error.CmarkMissingUrl;
                try writer.writeAll("<a ");
                try xml.writeAttribute(writer, "href", std.mem.span(url));
                try writer.writeAll(">");
            } else {
                try writer.writeAll("</a>");
            }
        },
        c.CMARK_NODE_IMAGE => {
            if (open) {
                const url = c.cmark_node_get_url(node) orelse return error.CmarkMissingUrl;
                try writer.writeAll("<img ");
                try xml.writeAttribute(writer, "src", std.mem.span(url));
                try writer.writeAll(" alt=\"");
            } else {
                try writer.writeAll("\"");
                const title = c.cmark_node_get_title(node) orelse return error.CmarkMissingTitle;
                if (title[0] != 0) {
                    try xml.writeAttribute(writer, " title", std.mem.span(title));
                }
                try writer.writeAll(" />");
            }
        },
        c.CMARK_NODE_FOOTNOTE_REFERENCE => {
            return error.CmarkFootnotesCurrentlyUnsupported;
        },
        else => |node_type| {
            std.debug.print("unexpected cmark node type: {}\n", .{node_type});
            return error.CmarkUnexpectedNodeType;
        },
    }
}

fn testWriter(buf: *std.BoundedArray(u8, 128)) std.BoundedArray(u8, 128).Writer {
    buf.len = 0;
    return buf.writer();
}
