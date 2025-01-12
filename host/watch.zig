// Recusrively watching the project directory for changes in source files.
// Currently only contains support for Linux using the fanotify API.

const builtin = @import("builtin");
const watch_linux = @import("watch-linux.zig");
const watch_macos = @import("watch-macos.zig");

pub const Watcher = switch (builtin.target.os.tag) {
    .linux => watch_linux.Watcher,
    .macos => watch_macos.Watcher,
    else => @compileError("unsupported OS"),
};
