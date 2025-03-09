// Functions and types for interacting with the platform code.

const builtin = @import("builtin");
const fail = @import("fail.zig");
const std = @import("std");
const RocStr = @import("roc/str.zig").RocStr;
const RocList = @import("roc/list.zig").RocList;
const Site = @import("site.zig").Site;
const Str = @import("str.zig").Str;
const xml = @import("xml.zig");
const glob = @import("glob.zig");

// When we call out to the platform, it in turn might run effects calling back
// into the host, specifically this code. Those incoming calls will lack the
// stack variables of the outgoing ones, so we store that on this variable.
threadlocal var pipeline_state: ?PipelineState = null;
const PipelineState = struct {
    site: *Site,
    arena: std.mem.Allocator,
    active_source_path: Str,
};

const Rule = extern struct {
    patterns: RocList,
    replace_tags: RocList,
    processing: Processing,
};

const Page = extern struct {
    meta: RocList,
    path: RocStr,
    tags: RocList,
    len: u32,
    rule_index: u32,
};

const Processing = enum(u8) {
    bootstrap = 0,
    ignore = 1,
    markdown = 2,
    none = 3,
    xml = 4,
};

const Tag = extern struct {
    attributes: RocList,
    index: u32,
    inner_end: u32,
    inner_start: u32,
    outer_end: u32,
    outer_start: u32,
};

const Slice = extern struct {
    payload: SlicePayload,
    tag: SliceTag,
};

const SlicePayload = extern union {
    from_source: SourceLoc,
    roc_generated: RocList,
};

const SliceTag = enum(u8) {
    from_source = 0,
    roc_generated = 1,
};

const SourceLoc = extern struct {
    end: u32,
    start: u32,
};

export fn roc_fx_list(pattern: *RocStr) callconv(.C) RocList {
    if (getPagesMatchingPattern(pattern)) |results| {
        return results;
    } else |err| {
        fail.crudely(err, @errorReturnTrace());
    }
}

fn getPagesMatchingPattern(roc_pattern: *RocStr) !RocList {
    const state = pipeline_state orelse return error.PipelineStateNotSet;
    const pattern = roc_pattern.asSlice();
    var results = std.ArrayList(Page).init(state.arena);
    var pages = try state.site.pagesMatchingPattern(state.active_source_path, pattern);
    while (pages.next()) |page| {
        const scanned = page.scanned orelse return error.UnexpectedUnscannedPage;
        try results.append(Page{
            .meta = RocList.fromSlice(u8, scanned.frontmatter orelse "{}", false),
            .path = try formatWebPath(state.arena, scanned.web_path),
            .tags = RocList.empty(),
            .len = 0,
            .rule_index = @as(u32, @intCast(page.rule_index)),
        });
    }
    return RocList.fromSlice(Page, try results.toOwnedSlice(), true);
}

extern fn roc__main_for_host_1_exposed_generic(*RocList, *const void) callconv(.C) void;
extern fn roc__get_metadata_length_for_host_1_exposed_generic(*u64, *const RocList) callconv(.C) void;
extern fn roc__run_pipeline_for_host_1_exposed_generic(*RocList, *const Page) callconv(.C) void;

pub const Platform = struct {
    deinit_: *const fn (
        platform: *Platform,
    ) void,
    get_rules: *const fn (
        platform: *Platform,
        gpa: std.mem.Allocator,
        site: *Site,
    ) anyerror!bool,
    get_metadata_length: *const fn (
        platform: *Platform,
        bytes: []const u8,
    ) u64,
    run_pipeline: *const fn (
        platform: *Platform,
        arena: std.mem.Allocator,
        site: *Site,
        page: *Site.Page,
        tags: []const xml.Tag,
        source: []const u8,
        writer: std.io.AnyWriter,
    ) anyerror!void,

    pub fn deinit(platform: *Platform) void {
        return platform.deinit_(platform);
    }

    pub fn getRules(
        platform: *Platform,
        gpa: std.mem.Allocator,
        site: *Site,
    ) anyerror!bool {
        return platform.get_rules(platform, gpa, site);
    }

    pub fn getMetadataLength(
        platform: *Platform,
        bytes: []const u8,
    ) u64 {
        return platform.get_metadata_length(platform, bytes);
    }

    pub fn runPipeline(
        platform: *Platform,
        arena: std.mem.Allocator,
        site: *Site,
        page: *Site.Page,
        tags: []const xml.Tag,
        source: []const u8,
        writer: std.io.AnyWriter,
    ) anyerror!void {
        return platform.run_pipeline(
            platform,
            arena,
            site,
            page,
            tags,
            source,
            writer,
        );
    }
};

pub const RocPlatform = struct {
    const Self = @This();

    gpa: std.mem.Allocator,
    platform: Platform,
    roc_main: *const fn (*RocList, *const void) callconv(.C) void,
    roc_get_metadata_length: *const fn (*u64, *const RocList) callconv(.C) void,
    roc_run_pipeline: *const fn (*RocList, *const Page) callconv(.C) void,

    pub fn init(gpa: std.mem.Allocator) !*Platform {
        return initHelper(
            gpa,
            &roc__main_for_host_1_exposed_generic,
            &roc__get_metadata_length_for_host_1_exposed_generic,
            &roc__run_pipeline_for_host_1_exposed_generic,
        );
    }

    fn initHelper(
        gpa: std.mem.Allocator,
        roc_main: *const fn (*RocList, *const void) callconv(.C) void,
        roc_get_metadata_length: *const fn (*u64, *const RocList) callconv(.C) void,
        roc_run_pipeline: *const fn (*RocList, *const Page) callconv(.C) void,
    ) !*Platform {
        const self = try gpa.create(Self);
        self.* = .{
            .gpa = gpa,
            .platform = Platform{
                .get_rules = getRules,
                .get_metadata_length = getMetadataLength,
                .run_pipeline = runPipeline,
                .deinit_ = deinit,
            },
            .roc_main = roc_main,
            .roc_get_metadata_length = roc_get_metadata_length,
            .roc_run_pipeline = roc_run_pipeline,
        };
        return &self.platform;
    }

    pub fn deinit(platform: *Platform) void {
        const self: *Self = @fieldParentPtr("platform", platform);
        self.gpa.destroy(self);
    }

    fn getRules(platform: *Platform, gpa: std.mem.Allocator, site: *Site) !bool {
        const self: *Self = @fieldParentPtr("platform", platform);
        var roc_rules = RocList.empty();
        self.roc_main(&roc_rules, &void{});
        var should_bootstrap = false;
        var rules = std.ArrayList(Site.Rule).init(gpa);
        errdefer rules.deinit();
        var ignore_patterns = std.ArrayList(Str).fromOwnedSlice(
            gpa,
            try gpa.dupe(Str, site.ignore_patterns),
        );
        errdefer ignore_patterns.deinit();
        var roc_rule_iterator = RocListIterator(Rule).init(roc_rules);
        const arena = site.allocator();
        while (roc_rule_iterator.next()) |platform_rule| {
            switch (platform_rule.processing) {
                .none, .xml, .markdown => {
                    const rule = Site.Rule{
                        .patterns = try rocListMapToOwnedSlice(
                            RocStr,
                            Str,
                            Str.Registry,
                            fromRocStr,
                            arena,
                            site.strs,
                            platform_rule.patterns,
                        ),
                        .replace_tags = try rocListMapToOwnedSlice(
                            RocStr,
                            Str,
                            Str.Registry,
                            fromRocStr,
                            arena,
                            site.strs,
                            platform_rule.replace_tags,
                        ),
                        .processing = @as(Site.Processing, @enumFromInt(@intFromEnum(platform_rule.processing))),
                    };
                    try rules.append(rule);
                },
                .ignore => {
                    const patterns = try rocListMapToOwnedSlice(
                        RocStr,
                        Str,
                        Str.Registry,
                        fromRocStr,
                        arena,
                        site.strs,
                        platform_rule.patterns,
                    );
                    try ignore_patterns.appendSlice(patterns);
                },
                .bootstrap => {
                    should_bootstrap = true;
                },
            }
        }
        site.rules = try arena.dupe(Site.Rule, try rules.toOwnedSlice());
        site.ignore_patterns = try arena.dupe(Str, try ignore_patterns.toOwnedSlice());
        return should_bootstrap;
    }

    fn getMetadataLength(platform: *Platform, bytes: []const u8) u64 {
        const self: *Self = @fieldParentPtr("platform", platform);
        var meta_len: u64 = undefined;
        const roc_bytes = RocList.fromSlice(u8, bytes, false);
        self.roc_get_metadata_length(&meta_len, &roc_bytes);
        return meta_len;
    }

    fn runPipeline(
        platform: *Platform,
        arena: std.mem.Allocator,
        site: *Site,
        page: *Site.Page,
        tags: []const xml.Tag,
        source: []const u8,
        writer: std.io.AnyWriter,
    ) !void {
        const self: *Self = @fieldParentPtr("platform", platform);
        const scanned = page.scanned orelse return error.CantRunPipelineForUnscannedPage;
        var roc_tags = std.ArrayList(Tag).init(arena);
        for (tags) |tag| {
            try roc_tags.append(Tag{
                .attributes = RocList.fromSlice(u8, tag.attributes, false),
                .outer_start = @as(u32, @intCast(tag.outer_start)),
                .outer_end = @as(u32, @intCast(tag.outer_end)),
                .inner_start = @as(u32, @intCast(tag.inner_start)),
                .inner_end = @as(u32, @intCast(tag.inner_end)),
                .index = @as(u32, @intCast(tag.index)),
            });
        }
        const roc_page = Page{
            .meta = RocList.fromSlice(u8, scanned.frontmatter orelse "{}", false),
            .path = try formatWebPath(arena, scanned.web_path),
            .rule_index = @as(u32, @intCast(page.rule_index)),
            .tags = RocList.fromSlice(Tag, try roc_tags.toOwnedSlice(), true),
            .len = @as(u32, @intCast(source.len)),
        };
        var contents = RocList.empty();

        pipeline_state = .{
            .site = site,
            .arena = arena,
            .active_source_path = page.source_path,
        };
        errdefer pipeline_state = null;
        self.roc_run_pipeline(&contents, &roc_page);
        pipeline_state = null;

        var roc_xml_iterator = RocListIterator(Slice).init(contents);
        while (roc_xml_iterator.next()) |roc_slice| {
            switch (roc_slice.tag) {
                .from_source => {
                    const slice = roc_slice.payload.from_source;
                    try writer.writeAll(source[slice.start..slice.end]);
                },
                .roc_generated => {
                    const roc_slice_list = roc_slice.payload.roc_generated;
                    const len = roc_slice_list.len();
                    if (len == 0) continue;
                    const slice = roc_slice_list.elements(u8) orelse return error.RocListUnexpectedEmpty;
                    try writer.writeAll(slice[0..len]);
                },
            }
        }
    }
};

pub const BootstrapPlatform = struct {
    const Self = @This();

    gpa: std.mem.Allocator,
    platform: Platform,

    pub fn init(gpa: std.mem.Allocator) !*Platform {
        const self = try gpa.create(Self);
        self.* = .{
            .gpa = gpa,
            .platform = Platform{
                .get_rules = getRules,
                .get_metadata_length = getMetadataLength,
                .run_pipeline = runPipeline,
                .deinit_ = deinit,
            },
        };
        return &self.platform;
    }

    pub fn deinit(platform: *Platform) void {
        const self: *Self = @fieldParentPtr("platform", platform);
        self.gpa.destroy(self);
    }

    fn getRules(platform: *Platform, gpa: std.mem.Allocator, site: *Site) !bool {
        _ = platform;
        _ = gpa;
        _ = site;
        unreachable;
    }

    fn getMetadataLength(platform: *Platform, bytes: []const u8) u64 {
        const self: *Self = @fieldParentPtr("platform", platform);
        _ = self;
        var meta_len: u64 = undefined;
        const roc_bytes = RocList.fromSlice(u8, bytes, false);
        roc__get_metadata_length_for_host_1_exposed_generic(&meta_len, &roc_bytes);
        return meta_len;
    }

    fn runPipeline(
        platform: *Platform,
        arena: std.mem.Allocator,
        site: *Site,
        page: *Site.Page,
        tags: []const xml.Tag,
        source: []const u8,
        writer: std.io.AnyWriter,
    ) !void {
        const self: *Self = @fieldParentPtr("platform", platform);
        _ = self;
        _ = arena;
        _ = site;
        _ = page;
        _ = tags;
        try writer.writeAll(source);
    }
};

pub const TestPlatform = struct {
    const Self = @This();

    platform: Platform,

    pub fn init() !*Platform {
        const self = try std.testing.allocator.create(Self);
        self.* = .{
            .platform = Platform{
                .deinit_ = deinit,
                .get_rules = getRules,
                .get_metadata_length = getMetadataLength,
                .run_pipeline = runPipeline,
            },
        };
        return &self.platform;
    }

    pub fn deinit(platform: *Platform) void {
        const self: *Self = @fieldParentPtr("platform", platform);
        std.testing.allocator.destroy(self);
    }

    fn getRules(platform: *Platform, gpa: std.mem.Allocator, site: *Site) anyerror!bool {
        const self: *Self = @fieldParentPtr("platform", platform);
        _ = self;
        _ = gpa;
        _ = site;
        return false;
    }

    fn getMetadataLength(platform: *Platform, bytes: []const u8) u64 {
        const self: *Self = @fieldParentPtr("platform", platform);
        _ = self;
        return if (std.mem.indexOfScalar(u8, bytes, '}')) |index|
            index + 1
        else
            0;
    }

    fn runPipeline(
        platform: *Platform,
        arena: std.mem.Allocator,
        site: *Site,
        page: *Site.Page,
        tags: []const xml.Tag,
        source: []const u8,
        writer: std.io.AnyWriter,
    ) anyerror!void {
        const self: *Self = @fieldParentPtr("platform", platform);
        _ = self;
        // Any tags with a 'pattern' attribute, the contents will be replaced
        // with joined metadata of the files matching the pattern.
        _ = arena;
        const attr_key = "pattern=\"";
        var index: usize = 0;
        for (tags) |tag| {
            try writer.writeAll(source[index..tag.outer_start]);
            index = tag.outer_end;
            if (!std.mem.eql(u8, tag.name, "dep")) continue;
            const offset = std.mem.indexOf(u8, tag.attributes, attr_key).?;
            const start = offset + attr_key.len;
            const end = std.mem.indexOfScalarPos(u8, tag.attributes, start, '"').?;
            const pattern = tag.attributes[start..end];
            var pages = try site.pagesMatchingPattern(page.source_path, pattern);
            while (pages.next()) |dep| try writer.writeAll(dep.scanned.?.frontmatter orelse "{}");
        }
        try writer.writeAll(source[index..]);
    }
};

export fn roc_alloc(size: usize, alignment: u32) callconv(.C) *anyopaque {
    _ = alignment;
    return std.c.malloc(size).?;
}

export fn roc_realloc(old_ptr: *anyopaque, new_size: usize, old_size: usize, alignment: u32) callconv(.C) ?*anyopaque {
    _ = old_size;
    _ = alignment;
    return std.c.realloc(old_ptr, new_size);
}

export fn roc_dealloc(c_ptr: *anyopaque, alignment: u32) callconv(.C) void {
    _ = alignment;
    std.c.free(c_ptr);
}

// The platform code uses 'crash' to 'throw' an error to the host in certain
// situations. We can kind of get away with it because compile-time and
// runtime are essentially the same time for this program, and so runtime
// errors have fewer downsides then they might have in other platforms.
//
// To distinguish platform panics from user panics, we prefix platform panics
// with a ridiculous string that hopefully never will attempt to copy.
const panic_prefix = "@$%^&.jayerror*";
export fn roc_panic(roc_msg: *RocStr, tag_id: u32) callconv(.C) void {
    const msg = roc_msg.asSlice();
    if (!std.mem.startsWith(u8, msg, panic_prefix)) {
        fail.prettily(
            \\
            \\Roc crashed with the following error:
            \\MSG:{s}
            \\TAG:{d}
            \\
            \\Shutting down
            \\
        , .{ msg, tag_id }) catch {};
        std.process.exit(1);
    }

    const code = msg[panic_prefix.len];
    const details = msg[panic_prefix.len + 2 ..];
    const state = pipeline_state orelse @panic("pipeline state not set");
    switch (code) {
        '0' => {
            fail.prettily(
                \\I ran into an error decoding metadata for this file:
                \\
                \\{s}
                \\
                \\The metadata:
                \\
                \\{s}
                \\
            , .{ state.active_source_path.bytes(), details }) catch {};
            std.process.exit(1);
        },
        '1' => {
            fail.prettily(
                \\I ran into an error generating output for this file:
                \\
                \\{s}
                \\
                \\I was parsing the attributes of an HTML element that is the
                \\target of a `Page.replace_html` call, but the attributes
                \\appear to be invalid:
                \\
                \\{s}
                \\
            , .{ state.active_source_path.bytes(), details }) catch {};
            std.process.exit(1);
        },
        else => {
            fail.prettily("Unknown panic error code: {d}", .{code}) catch {};
            std.process.exit(1);
        },
    }
}

export fn roc_dbg(loc: *RocStr, msg: *RocStr, src: *RocStr) callconv(.C) void {
    const stderr = std.io.getStdErr().writer();
    stderr.print("[{s}] {s} = {s}\n", .{ loc.asSlice(), src.asSlice(), msg.asSlice() }) catch unreachable;
}

export fn roc_memset(dst: [*]u8, value: i32, size: usize) callconv(.C) void {
    return @memset(dst[0..size], @intCast(value));
}

fn roc_getppid() callconv(.C) c_int {
    // Only recently added to Zig: https://github.com/ziglang/zig/pull/20866
    return @bitCast(@as(u32, @truncate(std.os.linux.syscall0(.getppid))));
}

fn roc_getppid_windows_stub() callconv(.C) c_int {
    return 0;
}

fn roc_shm_open(name: [*:0]const u8, oflag: c_int, mode: u16) callconv(.C) c_int {
    return std.c.shm_open(name, oflag, mode);
}

fn roc_mmap(addr: ?*align(std.heap.page_size_min) anyopaque, length: usize, prot: c_uint, flags: std.c.MAP, fd: c_int, offset: c_int) callconv(.C) *anyopaque {
    return std.c.mmap(addr, length, prot, flags, fd, offset);
}

comptime {
    if (builtin.os.tag == .macos or builtin.os.tag == .linux) {
        @export(&roc_getppid, .{ .name = "roc_getppid", .linkage = .strong });
        @export(&roc_mmap, .{ .name = "roc_mmap", .linkage = .strong });
        @export(&roc_shm_open, .{ .name = "roc_shm_open", .linkage = .strong });
    }

    if (builtin.os.tag == .windows) {
        @export(&roc_getppid_windows_stub, .{ .name = "roc_getppid", .linkage = .strong });
    }
}

fn RocListIterator(comptime T: type) type {
    return struct {
        const Self = @This();

        elements: ?[*]T,
        len: usize,
        index: usize,

        fn init(list: RocList) Self {
            return Self{
                .elements = list.elements(T),
                .len = list.len(),
                .index = 0,
            };
        }

        fn next(self: *Self) ?T {
            if (self.index < self.len) {
                const elem = self.elements.?[self.index];
                self.index += 1;
                return elem;
            } else {
                return null;
            }
        }
    };
}

fn rocListMapToOwnedSlice(
    comptime T: type,
    comptime O: type,
    comptime C: type,
    comptime map: fn (context: C, elem: T) anyerror!O,
    allocator: std.mem.Allocator,
    context: C,
    list: RocList,
) ![]O {
    const len = list.len();
    if (len == 0) return allocator.alloc(O, 0);
    const elements = list.elements(T) orelse return error.RocListUnexpectedlyEmpty;
    const slice = try allocator.alloc(O, len);
    for (elements, 0..len) |element, index| {
        slice[index] = try map(context, element);
    }
    return slice;
}

fn fromRocStr(strs: Str.Registry, roc_pattern: RocStr) !Str {
    return strs.intern(roc_pattern.asSlice());
}

fn getPagesMatchingPatternTest(roc_pattern: *RocStr) anyerror!RocList {
    _ = roc_pattern;
    return RocList.empty();
}

fn formatWebPath(arena: std.mem.Allocator, path: Str) !RocStr {
    const abs_path = try std.fmt.allocPrint(arena, "/{s}", .{path.bytes()});
    return RocStr.fromSlice(abs_path);
}
