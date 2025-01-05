// Integration with tree-sitter-highlight, for syntax highlighting in Markdown
// code blocks.

const std = @import("std");
const Grammar = @import("generated_grammars");
const native_endian = @import("builtin").target.cpu.arch.endian();
const ts = @import("tree_sitter");
const Str = @import("str.zig").Str;
const xml = @import("xml.zig");

const file_types = std.StaticStringMap(Grammar.Lang).initComptime(.{
    .{ "elm", .elm },
    .{ "haskell", .haskell },
    .{ "hs", .haskell },
    .{ "json", .json },
    .{ "nix", .nix },
    .{ "rb", .ruby },
    .{ "roc", .roc },
    .{ "rs", .rust },
    .{ "ruby", .ruby },
    .{ "rust", .rust },
    .{ "rvn", .roc },
    .{ "zig", .zig },
});

pub fn highlight(
    file_type: []const u8,
    input: []const u8,
    writer: anytype,
) !bool {
    const lang = file_types.get(file_type) orelse return false;
    const grammar = Grammar.all[@intFromEnum(lang)];
    const ts_lang = grammar.ts_language();
    defer ts_lang.destroy();

    const parser = ts.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(ts_lang);

    // TODO: switch to parser.parseInput to take input in a streaming fashion.
    const tree = try parser.parseBuffer(input, null, null);
    defer tree.destroy();

    const node = tree.rootNode();
    var error_offset: u32 = 0;
    const query = try ts.Query.create(
        ts_lang,
        std.mem.span(grammar.highlights_query),
        &error_offset,
    );
    defer query.destroy();

    const cursor = ts.QueryCursor.create();
    defer cursor.destroy();
    cursor.exec(query, node);

    var offset: u32 = 0;
    while (cursor.nextMatch()) |match| {
        std.debug.assert(match.captures.len > 0);
        const capture = match.captures[0].node;
        const range = capture.range();
        const name = query.captureNameForId(match.captures[0].index) orelse return error.HighlightUnknownPatternIndex;
        if (range.start_byte < offset) continue;
        try writer.writeAll(input[offset..range.start_byte]);
        try writer.writeAll("<span class=\"");
        var name_iter = std.mem.split(u8, name, ".");
        if (name_iter.next()) |name_part| {
            try writer.print("hl-{s}", .{name_part});
        }
        while (name_iter.next()) |name_part| {
            try writer.print(" hl-{s}", .{name_part});
        }
        try writer.writeAll("\">");
        try xml.writeEscaped(writer, input[range.start_byte..range.end_byte]);
        try writer.writeAll("</span>");
        offset = range.end_byte;
    }
    try writer.writeAll(input[offset..]);

    return true;
}

test highlight {
    var buf: [1024]u8 = undefined;
    var stream = std.io.FixedBufferStream([]u8){ .buffer = &buf, .pos = 0 };
    var writer = stream.writer();

    // Elm
    stream.reset();
    try std.testing.expect(try highlight("elm", "sum = 1 + 1", &writer));
    try std.testing.expectEqualStrings(
        \\<span class="hl-function hl-elm">sum</span> <span class="hl-keyword hl-operator hl-assignment hl-elm">=</span> <span class="hl-constant hl-numeric hl-elm">1</span> <span class="hl-keyword hl-operator hl-elm">+</span> <span class="hl-constant hl-numeric hl-elm">1</span>
    , stream.getWritten());

    // Haskell
    stream.reset();
    try std.testing.expect(try highlight("haskell", "sum = 1 + 1", &writer));
    try std.testing.expectEqualStrings(
        \\<span class="hl-function">sum</span> <span class="hl-operator">=</span> <span class="hl-number">1</span> <span class="hl-operator">+</span> <span class="hl-number">1</span>
    , stream.getWritten());

    // Json
    stream.reset();
    try std.testing.expect(try highlight("json", "{ \"hi\": 4 }", &writer));
    try std.testing.expectEqualStrings(
        \\{ <span class="hl-string hl-special hl-key">"hi"</span>: <span class="hl-number">4</span> }
    , stream.getWritten());

    // Nix
    stream.reset();
    try std.testing.expect(try highlight("nix", "sum = 1 + 1", &writer));
    try std.testing.expectEqualStrings(
        \\<span class="hl-function">sum</span> <span class="hl-punctuation hl-delimiter">=</span> <span class="hl-number">1</span> <span class="hl-operator">+</span> <span class="hl-number">1</span>
    , stream.getWritten());

    // Roc
    stream.reset();
    try std.testing.expect(try highlight("roc", "sum = 1 + 1", &writer));
    try std.testing.expectEqualStrings(
        \\<span class="hl-parameter hl-definition">sum</span> = <span class="hl-constant hl-numeric hl-integer">1</span> <span class="hl-operator">+</span> <span class="hl-constant hl-numeric hl-integer">1</span>
    , stream.getWritten());

    // Ruby
    stream.reset();
    try std.testing.expect(try highlight("ruby", "sum = 1 + 1", &writer));
    try std.testing.expectEqualStrings(
        \\<span class="hl-variable">sum</span> <span class="hl-operator">=</span> <span class="hl-number">1</span> + <span class="hl-number">1</span>
    , stream.getWritten());

    // Rust
    stream.reset();
    try std.testing.expect(try highlight("rust", "const sum: u32 = 1 + 1", &writer));
    try std.testing.expectEqualStrings(
        \\<span class="hl-keyword">const</span> <span class="hl-constant">sum</span><span class="hl-punctuation hl-delimiter">:</span> <span class="hl-type hl-builtin">u32</span> = <span class="hl-constant hl-builtin">1</span> + <span class="hl-constant hl-builtin">1</span>
    , stream.getWritten());

    // Zig
    stream.reset();
    try std.testing.expect(try highlight("zig", "const sum = 1 + 1", &writer));
    try std.testing.expectEqualStrings(
        \\<span class="hl-keyword">const</span> <span class="hl-variable">sum</span> <span class="hl-operator">=</span> <span class="hl-number">1</span> <span class="hl-operator">+</span> <span class="hl-number">1</span><span class="hl-punctuation hl-delimiter"></span>
    , stream.getWritten());
}
