const std = @import("std");
const c = @import("c.zig");

// This is a wrapper around tree-sitter-highlight, the companion object bundled
// with tree-sitter for syntax highlighting.
//
// I started with tree-sitter-highlight because it seems precisely what we
// need, but it's not a huge project and there's a couple of downsides to
// pulling it in: highlight is a rust project and requires libcpp. In a future
// version we might want to write our own highlighting straigt on top of
// tree-sitter.

pub fn highlight(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    const names: [2][*:0]const u8 = .{ "type", "variable" };
    var attrs: [names.len][*:0]const u8 = undefined;
    inline for (names, 0..) |name, index| {
        attrs[index] = std.fmt.comptimePrint("class=\"{s}\"", .{name});
    }

    var names_ = names;
    const highlighter = c.ts_highlighter_new(
        @ptrCast(&names_),
        @ptrCast(&attrs),
        names.len,
    );
    defer c.ts_highlighter_delete(highlighter);

    const highlight_query = @embedFile("queries/highlights.scm");
    const injection_query = @embedFile("queries/injections.scm");
    const locals_query = @embedFile("queries/locals.scm");
    const add_lang_err = c.ts_highlighter_add_language(
        highlighter,
        "roc",
        "roc",
        null,
        c.tree_sitter_roc(),
        highlight_query,
        injection_query,
        locals_query,
        highlight_query.len,
        injection_query.len,
        locals_query.len,
    );
    std.debug.assert(add_lang_err == 0);

    const buffer = c.ts_highlight_buffer_new();
    defer c.ts_highlight_buffer_delete(buffer);

    const highlight_err = c.ts_highlighter_highlight(
        highlighter,
        "roc",
        @ptrCast(input),
        @intCast(input.len),
        buffer,
        null,
    );
    std.debug.assert(highlight_err == 0);

    const output_len = c.ts_highlight_buffer_len(buffer);
    const output_bytes = c.ts_highlight_buffer_content(buffer);
    return allocator.dupe(u8, output_bytes[0..output_len]);
}

test highlight {
    const input = "sum = 1 + 1";
    const output = try highlight(std.testing.allocator, input);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        \\<span class="variable">sum</span> = 1 + 1
        \\
    , output);
}
