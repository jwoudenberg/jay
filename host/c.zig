// Zig recommends including all C dependencies using a single @cImport(..)
// call. This module makes that call, then exposes the result for other code.

const std = @import("std");
const native_endian = @import("builtin").target.cpu.arch.endian();

pub usingnamespace @cImport({
    @cInclude("cmark-gfm.h");
});
