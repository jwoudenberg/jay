const std = @import("std");
const Str = @import("str.zig").Str;

pub const Error = union(enum) {
    no_rule_for_page: Str,
    conflicting_rules: struct {
        source_path: Str,
        rule_indices: [2]usize,
    },
    conflicting_source_files: struct {
        web_path: Str,
        source_paths: [2]Str,
    },

    fn print(self: Error, writer: anytype) !void {
        switch (self) {
            .no_rule_for_page => {
                const source_path = self.no_rule_for_page;
                try writer.print(
                    \\I can't find a pattern matching the following source path:
                    \\
                    \\    {s}
                    \\
                    \\Make sure each path in your project directory is matched by
                    \\a rule, or an ignore pattern.
                    \\
                    \\Tip: Add an extra rule like this:
                    \\
                    \\    Pages.files ["{s}"]
                    \\
                    \\
                , .{ source_path.bytes(), source_path.bytes() });
            },
            .conflicting_rules => {
                const err = self.conflicting_rules;
                try writer.print(
                    \\The following file is matched by multiple rules:
                    \\
                    \\    {s}
                    \\
                    \\These are the indices of the rules that match:
                    \\
                    \\    {any}
                    \\
                    \\
                , .{ err.source_path.bytes(), err.rule_indices });
            },
            .conflicting_source_files => {
                const err = self.conflicting_source_files;
                try writer.print(
                    \\I found multiple source files for a single page URL.
                    \\
                    \\These are the source files in question:
                    \\
                    \\  {s}
                    \\  {s}
                    \\
                    \\The URL path I would use for both of these is:
                    \\
                    \\  {s}
                    \\
                    \\Tip: Rename one of the files so both get a unique URL.
                    \\
                , .{
                    err.source_paths[0].bytes(),
                    err.source_paths[1].bytes(),
                    err.web_path.bytes(),
                });
            },
        }
    }

    pub const Index = struct {
        errors: std.AutoHashMap(Str, Error),
        changes_since_print: bool,

        pub fn init(gpa: std.mem.Allocator) Index {
            return .{
                .errors = std.AutoHashMap(Str, Error).init(gpa),
                .changes_since_print = false,
            };
        }

        pub fn deinit(self: *Index) void {
            self.errors.deinit();
        }

        pub fn add(self: *Index, source_path: Str, err: Error) !void {
            self.changes_since_print = true;
            try self.errors.put(source_path, err);
        }

        pub fn remove(self: *Index, source_path: Str) void {
            self.changes_since_print = true;
            _ = self.errors.remove(source_path);
        }

        pub fn print(self: *Index, writer: anytype) !void {
            if (!self.changes_since_print) return;
            self.changes_since_print = false;

            try writer.writeAll("\x1b[2J");
            var iterator = self.errors.valueIterator();

            const first = iterator.next() orelse return;
            try first.print(writer);

            while (iterator.next()) |err| {
                try writer.writeAll("\n----------------------------------------\n\n");
                try err.print(writer);
            }
        }
    };
};
