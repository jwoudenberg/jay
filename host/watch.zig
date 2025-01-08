// Recusrively watching the project directory for changes in source files.
// Currently only contains support for Linux using the fanotify API.

const builtin = @import("builtin");
const watch_linux = @import("watch-linux.zig");

pub const Watcher = switch (builtin.target.os.tag) {
    .linux => watch_linux.Watcher,
    else => @compileError("unsupported OS"),
};
