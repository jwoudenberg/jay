const std = @import("std");
const native_endian = @import("builtin").target.cpu.arch.endian();

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const deps = Deps.init(b, optimize, target);

    // Collect all .roc files, to make them dependencies for other commands.
    var platform_dir = try std.fs.cwd().openDir("platform", .{ .iterate = true });
    defer platform_dir.close();
    var platform_walker = try platform_dir.walk(b.allocator);
    defer platform_walker.deinit();
    var roc_paths = std.ArrayList(std.Build.LazyPath).init(b.allocator);
    defer roc_paths.deinit();
    while (try platform_walker.next()) |entry| {
        if (entry.kind != .file) continue;
        const roc_path = b.path("platform").path(b, entry.path);
        try roc_paths.append(roc_path);
    }

    buildDynhost(b, deps, optimize, target, roc_paths.items);
    const legacy = buildLegacy(b, deps, optimize, target);
    buildGlue(b);
    const docs = buildDocs(b, roc_paths.items);
    buildSite(b, docs, legacy);
    runTests(b, deps, optimize, target);

    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = b.path("platform"),
        .install_dir = .{ .prefix = {} },
        .install_subdir = "platform",
        .include_extensions = &.{"roc"},
    }).step);
}

fn buildDynhost(
    b: *std.Build,
    deps: Deps,
    optimize: std.builtin.OptimizeMode,
    target: std.Build.ResolvedTarget,
    roc_paths: []std.Build.LazyPath,
) void {
    // Build a fake application for this platform as a library, so we have an
    // object exposing the right functions to compile the host against. The
    // implementation of the fake app will later be replaced with whatever real
    // Roc application we compile.
    const libapp = b.addSystemCommand(&.{"roc"});
    libapp.addArgs(&.{ "build", "--lib" });
    libapp.addFileArg(b.path("platform/libapp.roc"));
    libapp.addArg("--output");
    const libapp_so = libapp.addOutputFileArg(makeTempFilePath(b, "libapp.so"));

    // Build the host. We're claiming to build an executable here, but I don't
    // think that's exactly right as the artifact produced here is not intended
    // to run on its own.
    const dynhost = b.addExecutable(.{
        .name = "dynhost",
        .root_source_file = b.path("host/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    dynhost.pie = true;
    dynhost.rdynamic = true;
    dynhost.bundle_compiler_rt = true;
    dynhost.root_module.stack_check = false;
    dynhost.linkLibC();
    dynhost.linkLibCpp(); // used by tree-sitter-highlight
    dynhost.addObjectFile(libapp_so);
    deps.install(dynhost);

    // Run the Roc surgical linker to tie together our Roc platform and host
    // into something that can be packed up and used as a platform by others.
    const host = b.addSystemCommand(&.{"roc"});
    host.addArg("preprocess-host");
    host.addFileArg(dynhost.getEmittedBin());
    host.addFileArg(b.path("platform/main.roc"));
    host.addFileArg(libapp_so);

    // Mark all .roc files as dependencies of the two roc commands above. That
    // way zig will know to rerun the roc commands when .roc files change.
    for (roc_paths) |roc_path| {
        libapp.addFileInput(roc_path);
        host.addFileInput(roc_path);
    }

    b.getInstallStep().dependOn(&b.addInstallFile(libapp_so, "platform/libapp.so").step);
    b.getInstallStep().dependOn(&b.addInstallFile(dynhost.getEmittedBin(), "platform/dynhost").step);
}

fn buildLegacy(
    b: *std.Build,
    deps: Deps,
    optimize: std.builtin.OptimizeMode,
    target: std.Build.ResolvedTarget,
) *std.Build.Step {
    // Build the host again, this time as a library for static linking.
    const libhost = b.addStaticLibrary(.{
        .name = "jay",
        .root_source_file = b.path("host/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    libhost.pie = true;
    libhost.rdynamic = true;
    libhost.bundle_compiler_rt = true;
    libhost.linkLibC(); // provides malloc/free/.. used in main.zig
    libhost.linkLibCpp(); // used by tree-sitter-highlight
    deps.install(libhost);

    // We need the host's object files along with any C dependencies to be
    // bundled in a single archive for the legacy linker. The below build
    // step combines archives using a small bash script included in this repo.
    const combine_archive = b.addSystemCommand(&.{"build/combine-archives.sh"});
    const combined_archive = combine_archive.addOutputFileArg(makeTempFilePath(b, "combined.a"));
    combine_archive.addFileArg(deps.libcmark_gfm.artifact("cmark-gfm").getEmittedBin());
    combine_archive.addFileArg(deps.libcmark_gfm.artifact("cmark-gfm-extensions").getEmittedBin());
    combine_archive.addFileArg(libhost.getEmittedBin());

    b.getInstallStep().dependOn(&b.addInstallFile(combined_archive, "platform/linux-x64.a").step);

    return &combine_archive.step;
}

fn buildGlue(b: *std.Build) void {
    // Present description of roc types from running 'roc glue'. Glue does not
    // currently generate types for Zig, so I only use the output from this
    // command as documentation for hand-writing roc types in zig host code.
    const glue = b.addSystemCommand(&.{"roc"});
    glue.addArgs(&.{"glue"});
    glue.addFileArg(b.path("build/glue.roc"));
    const glue_dir = glue.addOutputDirectoryArg(b.makeTempPath());
    glue.addFileArg(b.path("platform/main-glue.roc"));

    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = glue_dir,
        .install_dir = .{ .prefix = {} },
        .install_subdir = "glue",
    }).step);
}

fn buildDocs(
    b: *std.Build,
    roc_paths: []std.Build.LazyPath,
) *std.Build.Step {
    const docs = b.addSystemCommand(&.{"roc"});
    docs.setEnvironmentVariable("ROC_DOCS_URL_ROOT", "/docs");
    docs.addArgs(&.{"docs"});
    docs.addFileArg(b.path("platform/main.roc"));
    docs.addArgs(&.{"--output"});
    const docs_dir = docs.addOutputDirectoryArg(b.makeTempPath());

    // Mark all .roc files as dependencies of the two roc commands above. That
    // way zig will know to rerun the roc commands when .roc files change.
    for (roc_paths) |roc_path| docs.addFileInput(roc_path);

    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = docs_dir,
        .install_dir = .{ .prefix = {} },
        .install_subdir = "docs",
    }).step);

    return &docs.step;
}

fn buildSite(
    b: *std.Build,
    docs: *std.Build.Step,
    legacy: *std.Build.Step,
) void {
    const site = b.addSystemCommand(&.{"./site/build.roc"});
    site.addArgs(&.{ "--linker=legacy", "prod" });
    site.step.dependOn(docs);
    site.step.dependOn(legacy);
    const site_dir = site.addOutputDirectoryArg(b.makeTempPath());

    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = site_dir,
        .install_dir = .{ .prefix = {} },
        .install_subdir = "site",
    }).step);
}

fn runTests(
    b: *std.Build,
    deps: Deps,
    optimize: std.builtin.OptimizeMode,
    target: std.Build.ResolvedTarget,
) void {
    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("host/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_unit_tests.linkLibC(); // provides malloc/free/.. used in main.zig
    exe_unit_tests.linkLibCpp(); // used by tree-sitter-highlight
    deps.install(exe_unit_tests);

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}

fn makeTempFilePath(b: *std.Build, filename: []const u8) []const u8 {
    return b.pathJoin(&[_][]const u8{ b.makeTempPath(), filename });
}

const Grammar = struct {
    name: []const u8,
    c_source_files: []const []const u8,

    fn lang_name(self: *const Grammar) []const u8 {
        const prefix = "tree-sitter-";
        std.debug.assert(std.mem.startsWith(u8, self.name, prefix));
        return self.name[prefix.len..];
    }
};

const grammars = [_]Grammar{
    .{ .name = "tree-sitter-elm", .c_source_files = &.{ "parser.c", "scanner.c" } },
    .{ .name = "tree-sitter-haskell", .c_source_files = &.{ "parser.c", "scanner.c" } },
    .{ .name = "tree-sitter-json", .c_source_files = &.{"parser.c"} },
    .{ .name = "tree-sitter-nix", .c_source_files = &.{ "parser.c", "scanner.c" } },
    .{ .name = "tree-sitter-roc", .c_source_files = &.{ "parser.c", "scanner.c" } },
    .{ .name = "tree-sitter-ruby", .c_source_files = &.{ "parser.c", "scanner.c" } },
    .{ .name = "tree-sitter-rust", .c_source_files = &.{ "parser.c", "scanner.c" } },
    .{ .name = "tree-sitter-zig", .c_source_files = &.{"parser.c"} },
};

// This is a custom step that sets up the tree-sitter portion of the build
// graph, including grammars.
// Part of the work involves pulling highlighting queries out of the `queries/`
// sub-directories of the different grammars, and generating a zig module
// containing their contents. This portion of the work requires a custom build
// step. Once that custom step existed, it attracted the remainder of the
// tree-sitter build.
const GenerateGrammars = struct {
    step: std.Build.Step,
    query_dirs: [grammars.len]std.Build.LazyPath,
    generated_file: std.Build.GeneratedFile,
    module: *std.Build.Module,
    output_path: []const u8,

    pub fn create(
        b: *std.Build,
        optimize: std.builtin.OptimizeMode,
        target: std.Build.ResolvedTarget,
    ) *GenerateGrammars {
        const tree_sitter = pathFromEnvVar(b, "TREE_SITTER_PATH");
        const highlight = pathFromEnvVar(b, "HIGHLIGHT_PATH");
        const generate_grammars = b.allocator.create(GenerateGrammars) catch @panic("OOM");
        generate_grammars.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "GenerateGrammars",
                .owner = b,
                .makeFn = make,
            }),
            .query_dirs = undefined,
            .generated_file = .{ .step = &generate_grammars.step },
            .module = b.createModule(.{
                .root_source_file = .{
                    .generated = .{
                        .file = &generate_grammars.generated_file,
                    },
                },
            }),
            .output_path = std.fs.path.join(
                b.allocator,
                &.{ b.makeTempPath(), "generated_grammars.zig" },
            ) catch @panic("OOM"),
        };

        var module = generate_grammars.module;
        for (grammars, 0..) |grammar, index| {
            // Build grammar
            const dep = b.dependency(grammar.name, .{
                .target = target,
                .optimize = optimize,
            });
            var lib = b.addObject(.{
                .name = grammar.name,
                .target = target,
                .optimize = optimize,
            });
            lib.root_module.addCSourceFiles(.{
                .root = dep.path("src"),
                .files = grammar.c_source_files,
            });
            lib.linkLibC();
            lib.root_module.addIncludePath(tree_sitter.path(b, "include"));
            lib.root_module.addIncludePath(dep.path("src"));

            module.addObject(lib);
            generate_grammars.query_dirs[index] = dep.path("queries");
        }

        module.addIncludePath(highlight.path(b, "include"));
        module.addObjectFile(highlight.path(b, "lib/libtree_sitter_highlight.a"));
        module.addIncludePath(tree_sitter.path(b, "include"));
        module.addObjectFile(tree_sitter.path(b, "lib/libtree-sitter.a"));

        return generate_grammars;
    }

    pub fn make(step: *std.Build.Step, prog_node: std.Progress.Node) anyerror!void {
        _ = prog_node;
        const self: *GenerateGrammars = @fieldParentPtr("step", step);
        self.writeModule() catch |err| {
            return step.fail("Unable to write {s}: {s}", .{
                self.output_path, @errorName(err),
            });
        };
        self.generated_file.path = self.output_path;
    }

    fn writeModule(self: *GenerateGrammars) !void {
        const b = self.step.owner;
        const file = try std.fs.createFileAbsolute(self.output_path, .{});
        defer file.close();
        var writer = file.writer();
        try writer.writeAll(
            \\const std = @import("std");
            \\const Grammar = @This();
            \\
            \\pub const c = @cImport({
            \\    @cInclude("tree_sitter/api.h");
            \\    @cInclude("tree_sitter/highlight.h");
            \\});
            \\
        );
        for (grammars) |grammar| {
            try writer.print(
                "extern fn tree_sitter_{s}() callconv(.C) ?*const c.TSLanguage;\n",
                .{grammar.lang_name()},
            );
        }
        try writer.writeAll(
            \\
            \\name: [:0]const u8,
            \\highlights_query: [*:0]const u8,
            \\injections_query: [*:0]const u8 = "",
            \\locals_query: [*:0]const u8 = "",
            \\ts_highlighter: ?*c.TSHighlighter = null,
            \\ts_language: *const fn () callconv(.C) ?*const c.TSLanguage,
            \\
            \\pub const Lang = enum {
            \\
        );
        for (grammars) |grammar| {
            try writer.print("    {s},\n", .{grammar.lang_name()});
        }
        try writer.writeAll(
            \\};
            \\
            \\pub const all: []const Grammar = &.{
            \\
        );
        for (grammars, self.query_dirs) |grammar, query_dir_path| {
            const query_dir = try std.fs.openDirAbsolute(query_dir_path.getPath(b), .{});
            try writer.print(
                \\    Grammar{{
                \\        .name = "{s}",
                \\        .ts_language = &tree_sitter_{s},
                \\
            , .{
                grammar.lang_name(),
                grammar.lang_name(),
            });
            for ([_][]const u8{ "highlights.scm", "injections.scm", "locals.scm" }) |query| {
                var query_file = query_dir.openFile(query, .{}) catch |err| {
                    if (err == error.FileNotFound) continue else return err;
                };
                defer query_file.close();
                var reader = query_file.reader();
                try writer.print("        .{s}_query = \n", .{query[0 .. query.len - 4]});
                try copyLinesAddingPrefix(&reader, writer, "            \\\\");
                try writer.writeAll("        ,\n");
            }
            try writer.writeAll(
                \\    },
                \\
            );
        }
        try writer.writeAll(
            \\};
            \\
        );
    }
};

fn copyLinesAddingPrefix(reader: anytype, writer: anytype, prefix: []const u8) !void {
    while (true) {
        try writer.writeAll(prefix);
        reader.streamUntilDelimiter(writer, '\n', null) catch |err| {
            if (err == error.EndOfStream) {
                return writer.writeByte('\n');
            } else {
                return err;
            }
        };
        try writer.writeByte('\n');
    }
}

const Deps = struct {
    b: *std.Build,
    mime: *std.Build.Dependency,
    libcmark_gfm: *std.Build.Dependency,
    tree_sitter_grammars: *GenerateGrammars,

    fn init(
        b: *std.Build,
        optimize: std.builtin.OptimizeMode,
        target: std.Build.ResolvedTarget,
    ) Deps {
        return .{
            .b = b,
            .mime = b.dependency("mime", .{
                .target = target,
                .optimize = optimize,
            }),
            .libcmark_gfm = b.dependency("libcmark-gfm", .{
                .target = target,
                .optimize = optimize,
            }),
            .tree_sitter_grammars = GenerateGrammars.create(
                b,
                optimize,
                target,
            ),
        };
    }

    fn install(self: Deps, step: *std.Build.Step.Compile) void {
        step.linkLibrary(self.libcmark_gfm.artifact("cmark-gfm"));
        step.linkLibrary(self.libcmark_gfm.artifact("cmark-gfm-extensions"));
        step.root_module.addImport("mime", self.mime.module("mime"));
        // Adding an import does not appear to copy over the imported module's
        // include_dirs to the root module, so I'm doing this by hand.
        // This likely means I'm missing the better way to do this.
        step.root_module.addImport("generated_grammars", self.tree_sitter_grammars.module);
        for (self.tree_sitter_grammars.module.include_dirs.items) |include_dir| {
            step.root_module.include_dirs.append(self.b.allocator, include_dir) catch @panic("OOM");
        }
    }
};

fn pathFromEnvVar(b: *std.Build, key: []const u8) std.Build.LazyPath {
    const path: []const u8 = std.process.getEnvVarOwned(b.allocator, key) catch @panic("OOM");
    return .{ .cwd_relative = path };
}
