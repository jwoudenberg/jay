// Helpers for rendering errors to the user.

const builtin = @import("builtin");
const std = @import("std");

// For use in situations where we want to show a pretty helpful error.
// 'pretty' is relative, much work to do here to really live up to that.
pub fn prettily(comptime format: []const u8, args: anytype) !noreturn {
    if (!builtin.is_test) {
        const stderr = std.io.getStdErr().writer();
        try stderr.print(format, args);
    }
    return error.PrettyError;
}

// For use in theoretically-possible-but-unlikely scenarios that we don't want
// to write dedicated error messages for.
pub fn crudely(err: anyerror, opt_trace: ?*std.builtin.StackTrace) noreturn {
    // Make sure we only print if we didn't already show a pretty error.
    if (err != error.PrettyError) {
        prettily("Error: {s}", .{@errorName(err)}) catch {};
        if (opt_trace) |trace| std.debug.dumpStackTrace(trace.*);
    }
    std.process.exit(1);
}
