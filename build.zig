const std = @import("std");
const native_endian = @import("builtin").target.cpu.arch.endian();

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const deps = try Deps.init(b, optimize, target);

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
    for (deps.tree_sitter_grammars) |grammar| {
        combine_archive.addFileArg(grammar.getEmittedBin());
    }
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

const Deps = struct {
    b: *std.Build,
    options: *std.Build.Step.Options,
    highlight: std.Build.LazyPath,
    tree_sitter: std.Build.LazyPath,
    mime: *std.Build.Dependency,
    libcmark_gfm: *std.Build.Dependency,
    tree_sitter_grammars: []*std.Build.Step.Compile,

    fn init(
        b: *std.Build,
        optimize: std.builtin.OptimizeMode,
        target: std.Build.ResolvedTarget,
    ) !Deps {
        const tree_sitter = try pathFromEnvVar(b, "TREE_SITTER_PATH");

        // We're passing information about available grammers into the Zig
        // build as a couple of build options.
        //
        // The 'slices' build option contains one long slice containing
        // null-terminated slices.
        //
        // The 'grammars' option contains u32 indexes into the slices array.
        // Each grammar is represented by the following series of u32s.
        // Ideally this would be a struct, but the current version of Zig has
        // some code-generation troubles when attempting to pass complicated
        // types as a build option.
        //
        //     [name][highlights][injections][locals]
        //
        //       name: The name of the language the grammar is for.
        // highlights: The contents of queries/highlights.scm.
        // injections: The contents of queries/injections.scm.
        //     locals: The contents of queries/locals.scm.
        //
        var grammars_option = std.ArrayList(u32).init(b.allocator);

        var slices_option = std.ArrayList(u8).init(b.allocator);
        var slices_option_writer_state = std.io.countingWriter(slices_option.writer());
        var slices_option_writer = slices_option_writer_state.writer();

        const grammar_paths_env = try std.process.getEnvVarOwned(b.allocator, "TREE_SITTER_GRAMMAR_PATHS");
        var grammar_paths_iter = std.mem.splitScalar(u8, grammar_paths_env, ':');
        var grammar_steps = std.ArrayList(*std.Build.Step.Compile).init(b.allocator);

        while (grammar_paths_iter.next()) |grammar_path_slice| {
            const basename = std.fs.path.basename(grammar_path_slice);
            const grammar_path: std.Build.LazyPath = .{ .cwd_relative = grammar_path_slice };
            const name_start = 1 + std.mem.indexOfScalar(u8, basename, '-').?;
            const grammar_name = basename[name_start..];
            const prefix = "tree-sitter-";
            std.debug.assert(std.mem.startsWith(u8, grammar_name, prefix));
            const grammar = b.addStaticLibrary(.{
                .name = grammar_name,
                .target = target,
                .optimize = optimize,
            });
            grammar.root_module.addCSourceFile(.{ .file = grammar_path.path(b, "src/parser.c") });
            if (try fileExists(grammar_path_slice, "src/scanner.c")) {
                grammar.root_module.addCSourceFile(.{ .file = grammar_path.path(b, "src/scanner.c") });
            }
            grammar.linkLibC();
            grammar.root_module.addIncludePath(tree_sitter.path(b, "include"));
            grammar.root_module.addIncludePath(grammar_path.path(b, "src"));
            const source_path = try std.fmt.allocPrint(b.allocator, "include/{s}.h", .{grammar_name});
            const dest_path = try std.fmt.allocPrint(b.allocator, "{s}.h", .{grammar_name});
            grammar.installHeader(grammar_path.path(b, source_path), dest_path);
            try grammar_steps.append(grammar);

            const lang_name = grammar_name[prefix.len..];
            const grammar_dir = try std.fs.cwd().openDir(grammar_path_slice, .{});
            const highlights_query = try grammar_dir.readFileAlloc(
                b.allocator,
                "queries/highlights.scm",
                1024 * 1024,
            );
            defer b.allocator.free(highlights_query);
            const injections_query = grammar_dir.readFileAlloc(
                b.allocator,
                "queries/injections.scm",
                1024 * 1024,
            ) catch |err| blk: {
                if (err == error.FileNotFound) break :blk "" else return err;
            };
            defer b.allocator.free(injections_query);
            const locals_query = grammar_dir.readFileAlloc(
                b.allocator,
                "queries/locals.scm",
                1024 * 1024,
            ) catch |err| blk: {
                if (err == error.FileNotFound) break :blk "" else return err;
            };
            defer b.allocator.free(locals_query);

            // Write name
            try grammars_option.append(@intCast(slices_option_writer_state.bytes_written));
            try slices_option_writer.writeAll(lang_name);
            try slices_option_writer.writeByte(0);

            // Write queries/highlights.scm
            try grammars_option.append(@intCast(slices_option_writer_state.bytes_written));
            try slices_option_writer.writeAll(highlights_query);
            try slices_option_writer.writeByte(0);

            // Write queries/injections.scm
            try grammars_option.append(@intCast(slices_option_writer_state.bytes_written));
            try slices_option_writer.writeAll(injections_query);
            try slices_option_writer.writeByte(0);

            // Write queries/locals.scm
            try grammars_option.append(@intCast(slices_option_writer_state.bytes_written));
            try slices_option_writer.writeAll(locals_query);
            try slices_option_writer.writeByte(0);
        }

        var options = b.addOptions();
        options.addOption([]const u32, "grammars", try grammars_option.toOwnedSlice());
        options.addOption([]const u8, "slices", try slices_option.toOwnedSlice());

        return .{
            .b = b,
            .options = options,
            .highlight = try pathFromEnvVar(b, "HIGHLIGHT_PATH"),
            .tree_sitter = tree_sitter,
            .tree_sitter_grammars = grammar_steps.items,
            .mime = b.dependency("mime", .{
                .target = target,
                .optimize = optimize,
            }),
            .libcmark_gfm = b.dependency("libcmark-gfm", .{
                .target = target,
                .optimize = optimize,
            }),
        };
    }

    fn install(self: Deps, step: *std.Build.Step.Compile) void {
        step.linkLibrary(self.libcmark_gfm.artifact("cmark-gfm"));
        step.linkLibrary(self.libcmark_gfm.artifact("cmark-gfm-extensions"));
        step.root_module.addImport("mime", self.mime.module("mime"));

        step.addIncludePath(self.highlight.path(self.b, "include"));
        step.addObjectFile(self.highlight.path(self.b, "lib/libtree_sitter_highlight.a"));

        step.addIncludePath(self.tree_sitter.path(self.b, "include"));
        step.addObjectFile(self.tree_sitter.path(self.b, "lib/libtree-sitter.a"));

        step.root_module.addOptions("zig_build_options", self.options);

        for (self.tree_sitter_grammars) |grammar| {
            step.linkLibrary(grammar);
        }
    }
};

fn pathFromEnvVar(b: *std.Build, key: []const u8) !std.Build.LazyPath {
    const path: []const u8 = try std.process.getEnvVarOwned(b.allocator, key);
    return .{ .cwd_relative = path };
}

fn fileExists(dir_path: []const u8, sub_path: []const u8) !bool {
    var dir = try std.fs.cwd().openDir(dir_path, .{});
    defer dir.close();
    dir.access(sub_path, .{}) catch |err| {
        return if (err == error.FileNotFound) false else err;
    };
    return true;
}
