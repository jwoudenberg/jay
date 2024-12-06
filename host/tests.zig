// Run tests on this module to ensure they run on all the modules below.

comptime {
    _ = @import("bootstrap.zig");
    _ = @import("fail.zig");
    _ = @import("frontmatter.zig");
    _ = @import("generate.zig");
    _ = @import("glob.zig");
    _ = @import("main.zig");
    _ = @import("path.zig");
    _ = @import("platform.zig");
    _ = @import("scan.zig");
    _ = @import("serve.zig");
    _ = @import("site.zig");
    _ = @import("watch.zig");
    _ = @import("work.zig");
    _ = @import("xml.zig");
}
