// Recusrively watching the project directory for changes in source files.
// Currently only contains support for Linux using the fanotify API.

const builtin = @import("builtin");

pub const Watcher = switch (builtin.target.os.tag) {
    .linux => @import("watch-linux.zig").Watcher,
    .macos => @import("watch-macos.zig").Watcher,
    else => @compileError("unsupported OS"),
};
