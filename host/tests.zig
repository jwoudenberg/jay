// Run tests on this module to ensure they run on all the modules below.

comptime {
    _ = @import("bootstrap.zig");
    _ = @import("fail.zig");
    _ = @import("generate.zig");
    _ = @import("glob.zig");
    _ = @import("main.zig");
    _ = @import("platform.zig");
    _ = @import("scan.zig");
    _ = @import("server.zig");
    _ = @import("site.zig");
    _ = @import("util.zig");
    _ = @import("xml.zig");
}
