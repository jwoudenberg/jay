const RocStr = @import("roc/str.zig").RocStr;
const RocList = @import("roc/list.zig").RocList;
const Site = @import("site.zig").Site;

pub extern fn roc__mainForHost_1_exposed_generic(*RocList, *const void) callconv(.C) void;
pub extern fn roc__getMetadataLengthForHost_1_exposed_generic(*u64, *const RocList) callconv(.C) void;
pub extern fn roc__runPipelineForHost_1_exposed_generic(*RocList, *const Page) callconv(.C) void;

pub const Rule = extern struct {
    patterns: RocList,
    replaceTags: RocList,
    processing: Site.Processing,
};

pub const Page = extern struct {
    meta: RocList,
    path: RocStr,
    tags: RocList,
    len: u32,
    ruleIndex: u32,
};

pub const Tag = extern struct {
    attributes: RocList,
    index: u32,
    innerEnd: u32,
    innerStart: u32,
    outerEnd: u32,
    outerStart: u32,
};

pub const Slice = extern struct {
    payload: SlicePayload,
    tag: SliceTag,
};

pub const SlicePayload = extern union {
    from_source: SourceLoc,
    roc_generated: RocList,
};

pub const SliceTag = enum(u8) {
    from_source = 0,
    roc_generated = 1,
};

const SourceLoc = extern struct {
    end: u32,
    start: u32,
};
