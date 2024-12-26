const std = @import("std");
const zig_build_options = @import("zig_build_options");
const native_endian = @import("builtin").target.cpu.arch.endian();

pub usingnamespace @cImport({
    @cInclude("cmark-gfm.h");
    @cInclude("tree_sitter/api.h");
    @cInclude("tree_sitter/highlight.h");

    // Decoding the data on grammars passed in from build.zig. See that file
    // for documentation on the format and kind of data passed in.
    var offset: usize = 0;
    const grammars = zig_build_options.grammars;
    const slices = zig_build_options.slices;
    while (offset < grammars.len) {
        const name_start = grammars[offset];
        const name: [:0]const u8 = std.mem.span(@as([*:0]const u8, @ptrCast(slices[name_start..])));
        offset += 4;
        const header_path = std.fmt.comptimePrint("tree-sitter-{s}.h", .{name});
        @cInclude(header_path);
    }
});
