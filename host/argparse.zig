// Parsing command-line arguments Jay is started with.

const std = @import("std");

pub const Args = union(enum) {
    run_dev_mode: struct { argv0: []const u8 },
    run_prod_mode: struct { argv0: []const u8, output: []const u8 },
    show_help: struct { argv0: []const u8 },
    mistake_no_output_path_passed: struct { argv0: []const u8 },
    mistake_unknown_argument: struct { argv0: []const u8, arg: []const u8 },

    pub fn parse(args: anytype) !Args {
        const argv0 = args.next() orelse return error.EmptyArgv;
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "help")) {
                return .{ .show_help = .{ .argv0 = argv0 } };
            } else if (std.mem.eql(u8, arg, "prod")) {
                if (args.next()) |output_arg| {
                    return .{ .run_prod_mode = .{
                        .argv0 = argv0,
                        .output = output_arg,
                    } };
                } else {
                    return .{ .mistake_no_output_path_passed = .{
                        .argv0 = argv0,
                    } };
                }
            } else {
                return .{ .mistake_unknown_argument = .{
                    .argv0 = argv0,
                    .arg = arg,
                } };
            }
        }
        return .{ .run_dev_mode = .{ .argv0 = argv0 } };
    }
};

test Args {
    try std.testing.expectError(error.EmptyArgv, fakeParse(&.{}));

    try std.testing.expectEqualDeep(
        Args{ .show_help = .{ .argv0 = "./build.roc" } },
        try fakeParse(&.{ "./build.roc", "help" }),
    );

    try std.testing.expectEqualDeep(
        Args{ .run_dev_mode = .{ .argv0 = "./build.roc" } },
        try fakeParse(&.{"./build.roc"}),
    );

    try std.testing.expectEqualDeep(
        Args{ .run_prod_mode = .{ .argv0 = "./build.roc", .output = "./output" } },
        try fakeParse(&.{ "./build.roc", "prod", "./output" }),
    );

    try std.testing.expectEqualDeep(
        Args{ .mistake_no_output_path_passed = .{ .argv0 = "./build.roc" } },
        try fakeParse(&.{ "./build.roc", "prod" }),
    );

    try std.testing.expectEqualDeep(
        Args{ .mistake_unknown_argument = .{ .argv0 = "./build.roc", .arg = "whoops" } },
        try fakeParse(&.{ "./build.roc", "whoops" }),
    );
}

fn fakeParse(args: []const []const u8) !Args {
    var arg_iterator = SliceIterator([]const u8).init(args);
    return Args.parse(&arg_iterator);
}

fn SliceIterator(comptime T: type) type {
    return struct {
        const Self = @This();

        slice: []const T,
        next_index: usize,

        fn init(slice: []const T) Self {
            return .{
                .slice = slice,
                .next_index = 0,
            };
        }

        fn next(self: *Self) ?T {
            if (self.next_index < self.slice.len) {
                const elem = self.slice[self.next_index];
                self.next_index += 1;
                return elem;
            } else {
                return null;
            }
        }
    };
}
