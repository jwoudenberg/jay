const std = @import("std");
const zig_build_options = @import("zig_build_options");

pub usingnamespace @cImport({
    @cInclude("cmark-gfm.h");
    @cInclude("tree_sitter/api.h");
    @cInclude("tree_sitter/highlight.h");

    var grammar_paths_iter = std.mem.splitScalar(u8, zig_build_options.grammars, ':');
    while (grammar_paths_iter.next()) |grammar| {
        const basename = std.fs.path.basename(grammar);
        const name_start = 1 + std.mem.indexOfScalar(u8, basename, '-').?;
        const name = basename[name_start..];
        const header_path = std.fmt.comptimePrint("{s}.h", .{name});
        @cInclude(header_path);
    }
});
