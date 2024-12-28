const std = @import("std");
const c = @import("c.zig");
const zig_build_options = @import("zig_build_options");
const native_endian = @import("builtin").target.cpu.arch.endian();
const Str = @import("str.zig").Str;

const file_types = std.StaticStringMap(Lang).initComptime(.{
    .{ "elm", .elm },
    .{ "roc", .roc },
    .{ "rs", .rust },
    .{ "rust", .rust },
    .{ "rvn", .roc },
    .{ "zig", .zig },
});

// This is a wrapper around tree-sitter-highlight, the companion object bundled
// with tree-sitter for syntax highlighting.
//
// I started with tree-sitter-highlight because it seems precisely what we
// need, but it's not a huge project and there's a couple of downsides to
// pulling it in: highlight is a rust project and requires libcpp. In a future
// version we might want to write our own highlighting straigt on top of
// tree-sitter.
pub const Highlighter = struct {
    allocator: std.mem.Allocator,
    ts_highlight_buffer: *c.TSHighlightBuffer,
    strs: Str.Registry,

    pub fn init(gpa: std.mem.Allocator) !Highlighter {
        return Highlighter{
            .allocator = gpa,
            .ts_highlight_buffer = c.ts_highlight_buffer_new() orelse return error.FailedToCreateHighlightBuffer,
            .strs = try Str.Registry.init(gpa),
        };
    }

    pub fn deinit(self: *Highlighter) void {
        c.ts_highlight_buffer_delete(self.ts_highlight_buffer);
        self.strs.deinit();
    }

    pub fn highlight(
        self: *Highlighter,
        file_type: []const u8,
        input: []const u8,
    ) !?[]const u8 {
        const lang = file_types.get(file_type) orelse return null;
        const grammar = try self.getGrammar(lang);

        const highlight_err = c.ts_highlighter_highlight(
            grammar.ts_highlighter,
            grammar.name,
            @ptrCast(input),
            @intCast(input.len),
            self.ts_highlight_buffer,
            null,
        );
        if (highlight_err != 0) {
            std.debug.print("failed to run highlighting: {}\n", .{highlight_err});
            return error.FailedToRunHighlighting;
        }

        const output_len = c.ts_highlight_buffer_len(self.ts_highlight_buffer);
        const output_bytes = c.ts_highlight_buffer_content(self.ts_highlight_buffer);
        return output_bytes[0..output_len];
    }

    // Initialize a highligher for a language. Ideally we'd do this in comptime,
    // but because the the initialization is performed by extern C code that's not
    // possible, so instead we perform it at runtime. Dropping the dependency on
    // tree-sitter-highlight for our own code would allow us to improve this.
    fn getGrammar(
        self: *Highlighter,
        lang: Lang,
    ) !Grammar {
        var grammar: Grammar = grammars[@intFromEnum(lang)];
        if (grammar.ts_highlighter != null) return grammar;

        const highlights_query = std.mem.span(grammar.highlights_query);
        const injections_query = std.mem.span(grammar.injections_query);
        const locals_query = std.mem.span(grammar.locals_query);

        var names = std.ArrayHashMapUnmanaged(
            [*:0]const u8,
            [*:0]const u8,
            CStringContext,
            true,
        ){};
        try names.ensureTotalCapacity(self.allocator, 1000);
        defer names.deinit(self.allocator);

        var offset: usize = 0;
        var buffer = try std.BoundedArray(u8, 1000).init(0);
        var buf_writer = buffer.writer();
        while (std.mem.indexOfScalarPos(u8, highlights_query, offset, '@')) |start| {
            const end = std.mem.indexOfAnyPos(u8, highlights_query, start, " \t\n()") orelse highlights_query.len;
            offset = end;

            buffer.len = 0;
            try buf_writer.writeAll(highlights_query[1 + start .. end]);
            try buf_writer.writeByte(0);
            const name_z = buffer.constSlice()[0 .. buffer.len - 1 :0];
            const getOrPut = names.getOrPutAssumeCapacity(name_z);
            if (getOrPut.found_existing) continue;

            const name_interned = try self.strs.intern(buffer.constSlice());
            const name = name_interned.bytes()[0 .. buffer.len - 1 :0];
            getOrPut.key_ptr.* = name;

            // For a name:
            //
            //     variable.parameter
            //
            // Generate an attribute:
            //
            //     class="hl-variable hl-parameter"
            //
            buffer.len = 0;
            var name_offset: usize = 0;
            try buf_writer.writeAll("class=\"");
            while (std.mem.indexOfScalarPos(u8, name, name_offset, '.')) |chunk_end| {
                try buf_writer.print("hl-{s} ", .{name[name_offset..chunk_end]});
                name_offset = chunk_end + 1;
            }
            try buf_writer.print("hl-{s}\"\x00", .{name[name_offset..]});
            const attr_interned = try self.strs.intern(buffer.constSlice());
            const attr = attr_interned.bytes()[0 .. attr_interned.len() - 1 :0];
            getOrPut.value_ptr.* = attr;
        }

        grammar.ts_highlighter = c.ts_highlighter_new(
            @ptrCast(names.keys()),
            @ptrCast(names.values()),
            @intCast(names.count()),
        ) orelse return error.FailedToCreateHighlighter;

        const ts_language = grammar.ts_language() orelse return error.FailedToGetLanguage;

        const add_lang_err = c.ts_highlighter_add_language(
            grammar.ts_highlighter,
            grammar.name,
            grammar.name,
            null,
            ts_language,
            highlights_query,
            injections_query,
            locals_query,
            @intCast(highlights_query.len),
            @intCast(injections_query.len),
            @intCast(locals_query.len),
        );
        if (add_lang_err != 0) {
            std.debug.print("failed to add highlight language: {}\n", .{add_lang_err});
            return error.FailedToAddHighlightLanguage;
        }

        return grammar;
    }
};

test Highlighter {
    var highlighter = try Highlighter.init(std.testing.allocator);
    defer highlighter.deinit();

    // Elm
    try std.testing.expectEqualStrings(
        \\<span class="hl-function hl-elm">sum</span> <span class="hl-keyword hl-operator hl-assignment hl-elm">=</span> <span class="hl-constant hl-numeric hl-elm">1</span> <span class="hl-keyword hl-operator hl-elm">+</span> <span class="hl-constant hl-numeric hl-elm">1</span>
        \\
    ,
        (try highlighter.highlight("elm", "sum = 1 + 1")).?,
    );

    // Roc
    try std.testing.expectEqualStrings(
        \\<span class="hl-variable">sum</span> = <span class="hl-constant hl-numeric hl-integer">1</span> <span class="hl-operator">+</span> <span class="hl-constant hl-numeric hl-integer">1</span>
        \\
    ,
        (try highlighter.highlight("roc", "sum = 1 + 1")).?,
    );

    // Rust
    try std.testing.expectEqualStrings(
        \\<span class="hl-keyword">const</span> sum<span class="hl-punctuation hl-delimiter">:</span> <span class="hl-type hl-builtin">u32</span> = <span class="hl-constant hl-builtin">1</span> + <span class="hl-constant hl-builtin">1</span>
        \\
    ,
        (try highlighter.highlight("rust", "const sum: u32 = 1 + 1")).?,
    );

    // Zig
    try std.testing.expectEqualStrings(
        \\<span class="hl-type hl-qualifier">const</span> <span class="hl-variable">sum</span> = <span class="hl-number">1</span> <span class="hl-operator">+</span> <span class="hl-number">1</span><span class="hl-punctuation hl-delimiter"></span>
        \\
    ,
        (try highlighter.highlight("zig", "const sum = 1 + 1")).?,
    );
}

const Grammar = struct {
    name: [:0]const u8,
    highlights_query: [*:0]const u8,
    injections_query: [*:0]const u8 = "",
    locals_query: [*:0]const u8 = "",
    ts_highlighter: ?*c.TSHighlighter = null,
    ts_language: *const fn () callconv(.C) ?*const c.TSLanguage,
};

pub const CStringContext = struct {
    pub fn hash(self: @This(), s: [*:0]const u8) u32 {
        _ = self;
        return std.array_hash_map.hashString(std.mem.span(s));
    }
    pub fn eql(self: @This(), a: [*:0]const u8, b: [*:0]const u8, b_index: usize) bool {
        _ = self;
        _ = b_index;
        return std.array_hash_map.eqlString(std.mem.span(a), std.mem.span(b));
    }
};

// Create an enum for all the supported languages from the `grammars` array.
// The generated enum type is equivalent to the following hand-written one:
//
//     const Lang = enum { roc, zig, ... }
//
const Lang = blk: {
    var lang_enum_fields: [grammars.len]std.builtin.Type.EnumField = undefined;
    for (grammars, 0..) |lang, index| {
        lang_enum_fields[index] = .{
            .name = lang.name,
            .value = index,
        };
    }
    break :blk @Type(.{
        .Enum = .{
            .tag_type = u16,
            .is_exhaustive = true,
            .decls = &.{},
            .fields = &lang_enum_fields,
        },
    });
};

const grammars: []const Grammar = blk: {
    var output: [100]Grammar = undefined;
    var index = 0;

    // Decoding the data on grammars passed in from build.zig. See that file
    // for documentation on the format and kind of data passed in.
    var offset: usize = 0;
    const input = zig_build_options.grammars;
    const slices = zig_build_options.slices;
    while (offset < input.len) {
        const name_start = input[offset];
        const name: [:0]const u8 = std.mem.span(@as([*:0]const u8, @ptrCast(slices[name_start..])));
        offset += 1;

        const highlights_start = input[offset];
        const highlights_query: [*:0]const u8 = @ptrCast(slices[highlights_start..]);
        offset += 1;

        const injections_start = input[offset];
        const injections_query: [*:0]const u8 = @ptrCast(slices[injections_start..]);
        offset += 1;

        const locals_start = input[offset];
        const locals_query: [*:0]const u8 = @ptrCast(slices[locals_start..]);
        offset += 1;

        const ts_language_fn_name = std.fmt.comptimePrint(
            "tree_sitter_{s}",
            .{name},
        );
        const ts_language = @field(c, ts_language_fn_name);

        const grammar = Grammar{
            .name = name,
            .highlights_query = highlights_query,
            .injections_query = injections_query,
            .locals_query = locals_query,
            .ts_language = &ts_language,
        };
        output[index] = grammar;
        index += 1;
    }

    // Copy to const required because of how comptime works:
    // https://ziggit.dev/t/comptime-mutable-memory-changes/3702
    const result = output;
    break :blk result[0..index];
};
