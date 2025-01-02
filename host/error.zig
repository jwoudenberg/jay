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
    markdown_rule_applied_to_non_markdown_file: Str,
    invalid_frontmatter: Str,
    unsupported_source_file: struct {
        source_path: Str,
        kind: std.fs.File.Kind,
    },
    source_file_is_symlink: Str,

    fn print(self: Error, writer: anytype) !void {
        switch (self) {
            .no_rule_for_page => |payload| {
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
                , .{
                    payload.bytes(),
                    payload.bytes(),
                });
            },
            .conflicting_rules => |payload| {
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
                , .{ payload.source_path.bytes(), payload.rule_indices });
            },
            .conflicting_source_files => |payload| {
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
                    payload.source_paths[0].bytes(),
                    payload.source_paths[1].bytes(),
                    payload.web_path.bytes(),
                });
            },
            .markdown_rule_applied_to_non_markdown_file => |payload| {
                const path = payload.bytes();
                try writer.print(
                    \\One of the pages for a markdown rule does not have a
                    \\markdown extension:
                    \\
                    \\  {s}
                    \\
                    \\Maybe the file is in the wrong directory? If it really
                    \\contains markdown, consider renaming the file to:
                    \\
                    \\  {s}.md
                    \\
                , .{
                    path,
                    path[0..(path.len - std.fs.path.extension(path).len)],
                });
            },
            .invalid_frontmatter => |payload| {
                try writer.print(
                    \\There's something wrong with the frontmatter at the top
                    \\of this markdown file:
                    \\
                    \\  {s}
                    \\
                    \\I believe there's a frontmatter there because the file
                    \\starts with a '{{' character, but can't read the rest.
                    \\I'm expecting a valid Roc record.
                    \\
                    \\Tip: Copy the frontmatter into `roc repl` to validate it.
                    \\
                , .{payload.bytes()});
            },
            .unsupported_source_file => |payload| {
                try writer.print(
                    \\I came across a source file with type '{s}':
                    \\
                    \\  {s}
                    \\
                    \\I don't support files of type '{s}'. Please remove it, or
                    \\add an ignore pattern for it.
                    \\
                , .{
                    @tagName(payload.kind),
                    payload.source_path.bytes(),
                    @tagName(payload.kind),
                });
            },
            .source_file_is_symlink => |source_path| {
                try writer.print(
                    \\The following source file is a symlink:
                    \\
                    \\    {s}
                    \\
                    \\I don't currently support symlinks to individual source
                    \\files. If this functionality is important to you, I'd
                    \\love to hear about your usecase. Please create an issue
                    \\at https://github.com/jwoudenberg/jay. Thank you!
                    \\
                    \\Tip: I do support symlinks to directories, maybe that
                    \\     works as an alternative!
                    \\
                , .{source_path.bytes()});
            },
        }
    }

    pub const Index = struct {
        errors: std.AutoArrayHashMap(Str, Error),
        changes_since_print: bool,

        pub fn init(gpa: std.mem.Allocator) Index {
            return .{
                .errors = std.AutoArrayHashMap(Str, Error).init(gpa),
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
            _ = self.errors.orderedRemove(source_path);
        }

        pub fn print(self: *Index, writer: anytype) !void {
            if (!self.changes_since_print) return;
            self.changes_since_print = false;

            try writer.writeAll("\x1b[2J");
            var iterator = self.errors.iterator();

            const first = iterator.next() orelse return;
            try first.value_ptr.print(writer);

            while (iterator.next()) |entry| {
                try writer.writeAll("\n----------------------------------------\n\n");
                try entry.value_ptr.print(writer);
            }
        }

        pub fn has_errors(self: *Index) bool {
            return self.errors.count() > 0;
        }
    };
};
