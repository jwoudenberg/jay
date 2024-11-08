comptime {
    // To run tests from all modules when running tests in this module
    _ = @import("bootstrap.zig");
    _ = @import("fail.zig");
    _ = @import("generate.zig");
    _ = @import("glob.zig");
    _ = @import("lib.zig");
    _ = @import("main.zig");
    _ = @import("platform.zig");
    _ = @import("scan.zig");
    _ = @import("site.zig");
    _ = @import("util.zig");
    _ = @import("xml.zig");
}
