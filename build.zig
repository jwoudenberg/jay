const std = @import("std");
const native_endian = @import("builtin").target.cpu.arch.endian();

pub fn build(b: *std.Build) !void {
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

    const build_type = b.option(
        enum { dev, host, release, site },
        "type",
        "the type of build to perform",
    ) orelse .dev;
    switch (build_type) {
        .dev => buildDev(b, roc_paths.items),
        .host => buildHost(b),
        .site => buildSite(b, roc_paths.items),
        .release => buildRelease(b),
    }
}

fn buildRelease(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const targets = [_]std.Build.ResolvedTarget{
        std.Build.resolveTargetQuery(b, .{
            .cpu_arch = .x86_64,
            .os_tag = .linux,
        }),
        std.Build.resolveTargetQuery(b, .{
            .cpu_arch = .x86_64,
            .os_tag = .macos,
        }),
        std.Build.resolveTargetQuery(b, .{
            .cpu_arch = .aarch64,
            .os_tag = .macos,
        }),
    };
    const platform_bundle = std.Build.Step.WriteFile.create(b);
    for (targets) |target| {
        const deps = Deps.init(b, optimize, target);
        buildLegacy(b, deps, optimize, target, platform_bundle);
    }

    const bundle = b.addSystemCommand(&.{"roc"});
    bundle.addArgs(&.{ "build", "--bundle", ".tar.br" });
    bundle.addFileArg(platform_bundle.getDirectory().path(b, "main.roc"));
    bundle.step.dependOn(&platform_bundle.step);

    // The generated bundle filename contains a hash so we don't know exactly
    // what it will be. We abuse `addInstallDirectory` to find it by extension.
    const install_bundle = b.addInstallDirectory(.{
        .source_dir = platform_bundle.getDirectory(),
        .install_dir = .prefix,
        .install_subdir = "./",
        .include_extensions = &.{"tar.br"},
    });
    install_bundle.step.dependOn(&bundle.step);
    b.getInstallStep().dependOn(&install_bundle.step);
}

fn buildSite(b: *std.Build, roc_paths: []std.Build.LazyPath) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const deps = Deps.init(b, optimize, target);

    const platform_bundle = std.Build.Step.WriteFile.create(b);
    buildLegacy(b, deps, optimize, target, platform_bundle);
    const install_platform_bundle = b.addInstallDirectory(.{
        .source_dir = platform_bundle.getDirectory(),
        .install_dir = .prefix,
        .install_subdir = "platform",
    });

    const docs = buildDocs(b, roc_paths);

    const site = b.addSystemCommand(&.{"./site/build.roc"});
    site.addArgs(&.{ "--linker=legacy", "prod" });
    site.step.dependOn(docs);
    site.step.dependOn(&install_platform_bundle.step);
    const site_dir = site.addOutputDirectoryArg(b.makeTempPath());

    b.installDirectory(.{
        .source_dir = site_dir,
        .install_dir = .prefix,
        .install_subdir = "site",
    });
}

fn buildHost(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const deps = Deps.init(b, optimize, target);

    const platform_bundle = std.Build.Step.WriteFile.create(b);
    buildLegacy(b, deps, optimize, target, platform_bundle);
    b.installDirectory(.{
        .source_dir = platform_bundle.getDirectory(),
        .install_dir = .prefix,
        .install_subdir = "platform",
    });
}

fn buildDev(b: *std.Build, roc_paths: []std.Build.LazyPath) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const deps = Deps.init(b, optimize, target);

    buildDynhost(b, deps, optimize, target, roc_paths);

    const platform_bundle = std.Build.Step.WriteFile.create(b);
    buildLegacy(b, deps, optimize, target, platform_bundle);
    b.installDirectory(.{
        .source_dir = platform_bundle.getDirectory(),
        .install_dir = .prefix,
        .install_subdir = "platform",
    });

    runTests(b, deps, optimize, target);
    runIntegrationTests(b, deps, optimize, target);
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
    libapp.addArgs(&.{ "build", "--lib", "--target", formatTargetForRoc(b, target) });
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
    dynhost.bundle_compiler_rt = true;
    dynhost.pie = true;
    dynhost.root_module.stack_check = false;
    dynhost.linkLibC();
    dynhost.addObjectFile(libapp_so);
    deps.install(dynhost);

    // Run the Roc surgical linker to tie together our Roc platform and host
    // into something that can be packed up and used as a platform by others.
    const host = b.addSystemCommand(&.{ "roc", "--target", formatTargetForRoc(b, target) });
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
    platform_bundle: *std.Build.Step.WriteFile,
) void {
    // Build the host again, this time as a library for static linking.
    const libhost = b.addStaticLibrary(.{
        .name = "jay",
        .root_source_file = b.path("host/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    libhost.bundle_compiler_rt = true;
    libhost.pie = true;
    libhost.linkLibC(); // provides malloc/free/.. used in main.zig
    deps.install(libhost);
    const install_path = std.fmt.allocPrint(
        b.allocator,
        "{s}.a",
        .{formatTargetForRoc(b, target)},
    ) catch @panic("OOM");
    _ = platform_bundle.addCopyDirectory(
        b.path("platform"),
        "./",
        .{ .include_extensions = &.{"roc"} },
    );
    _ = platform_bundle.addCopyFile(libhost.getEmittedBin(), install_path);
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

    b.installDirectory(.{
        .source_dir = docs_dir,
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    return &docs.step;
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
    deps.install(exe_unit_tests);

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}

fn runIntegrationTests(
    b: *std.Build,
    deps: Deps,
    optimize: std.builtin.OptimizeMode,
    target: std.Build.ResolvedTarget,
) void {
    var dir = std.fs.cwd().openDir("examples", .{ .iterate = true }) catch @panic("can't open dir");
    defer dir.close();
    var iterator = dir.iterate();

    const platform_bundle = std.Build.Step.WriteFile.create(b);
    buildLegacy(b, deps, optimize, target, platform_bundle);
    const install_platform_bundle = b.addInstallDirectory(.{
        .source_dir = platform_bundle.getDirectory(),
        .install_dir = .prefix,
        .install_subdir = "platform",
    });

    const integration_test_step = b.step("integration-test", "Run integration tests");
    while (iterator.next() catch @panic("can't iterate examples")) |entry| {
        const path = std.fmt.allocPrint(
            b.allocator,
            "examples/{s}",
            .{entry.name},
        ) catch @panic("OOM");
        const single_test = RunIntegrationTest.create(b, path);
        single_test.step.dependOn(&install_platform_bundle.step);
        integration_test_step.dependOn(&single_test.step);
    }
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

const RunIntegrationTest = struct {
    const Self = @This();

    step: std.Build.Step,
    example_dir_path: []const u8,
    output_dir_path: std.Build.LazyPath,

    pub fn create(b: *std.Build, example_dir_path: []const u8) *std.Build.Step.Run {
        const self = b.allocator.create(Self) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "RunIntegrationTest",
                .owner = b,
                .makeFn = make,
            }),
            .example_dir_path = example_dir_path,
            .output_dir_path = undefined,
        };
        const cmd = std.fmt.allocPrint(b.allocator, "./{s}/build.roc", .{example_dir_path}) catch @panic("OOM");
        const build_example = b.addSystemCommand(&.{cmd});
        build_example.addArg("--linker=legacy");
        build_example.addArg("prod");
        self.output_dir_path = build_example.addOutputDirectoryArg(b.makeTempPath());
        self.step.dependOn(&build_example.step);
        return build_example;
    }

    pub fn make(step: *std.Build.Step, prog_node: std.Progress.Node) anyerror!void {
        _ = prog_node;
        const self: *Self = @fieldParentPtr("step", step);
        const b = self.step.owner;

        var example_dir = try std.fs.cwd().openDir(self.example_dir_path, .{ .iterate = false });
        defer example_dir.close();
        var expected_output = try example_dir.openDir("jay-output", .{ .iterate = true });
        defer expected_output.close();
        var expected_output_walker = try expected_output.walk(b.allocator);
        defer expected_output_walker.deinit();
        var expected_path_sets = std.BufSet.init(b.allocator);
        defer expected_path_sets.deinit();
        while (try expected_output_walker.next()) |entry| {
            if (entry.kind != .file) continue;
            try expected_path_sets.insert(entry.path);
        }

        var output_dir = try std.fs.cwd().openDir(
            self.output_dir_path.getPath(b),
            .{ .iterate = false },
        );
        defer output_dir.close();
        var actual_output = try output_dir.openDir("jay-output", .{ .iterate = true });
        defer actual_output.close();
        var actual_output_walker = try actual_output.walk(b.allocator);
        defer actual_output_walker.deinit();
        while (try actual_output_walker.next()) |entry| {
            if (entry.kind != .file) continue;
            if (expected_path_sets.contains(entry.path)) {
                expected_path_sets.remove(entry.path);
                const expected_contents = try expected_output.readFileAlloc(b.allocator, entry.path, 1000_000);
                const actual_contents = try actual_output.readFileAlloc(b.allocator, entry.path, 1000_000);
                if (!std.mem.eql(u8, expected_contents, actual_contents)) {
                    std.debug.print(
                        \\----- Failing integration test: {s}
                        \\Generated file has contents other than expected:
                        \\    {s}
                        \\
                    , .{ self.example_dir_path, entry.path });
                    try std.testing.expectEqualStrings(expected_contents, actual_contents);
                }
            } else {
                std.debug.print(
                    \\----- Failing integration test: {s}
                    \\Generated the following unexpected path:
                    \\    {s}
                    \\
                , .{ self.example_dir_path, entry.path });
                return error.FailingTest;
            }
        }

        var expected_path_iter = expected_path_sets.iterator();
        if (expected_path_iter.next()) |ungenerated_path| {
            std.debug.print(
                \\----- Failing integration test: {s}
                \\Expected the following file that was not generated:
                \\    {s}
                \\
            , .{ self.example_dir_path, ungenerated_path });
            return error.FailingTest;
        }
    }
};

// When linking a build step against a static library, the build system by
// default produces separate .a files for the compiled library and the
// dependency. Roc requires a single .a file per-platform, with a preset name.
//
// This custom step is like `std.Build.Module.addObject`, but instead takes an
// .a archive, unpacks the object files within, and adds them to another
// module.
//
// Some prior art here: https://ziggit.dev/t/build-zig-addobject-static-library/3368
const AddObjectArchive = struct {
    const Self = @This();

    step: std.Build.Step,
    destination: *std.Build.Step.Compile,
    source: *std.Build.Step.Compile,
    extracted_objs: std.Build.LazyPath,

    pub fn create(
        destination: *std.Build.Step.Compile,
        target: std.Build.ResolvedTarget,
        source: *std.Build.Step.Compile,
    ) *Self {
        const b = source.step.owner;
        const self = b.allocator.create(Self) catch @panic("OOM");

        const ar = b.addSystemCommand(&.{"zig"});
        ar.addArgs(&.{ "ar", "x", formatTargetForAr(b, target) });
        ar.addFileArg(source.getEmittedBin());
        ar.addArg("--output");
        const extracted_objs = ar.addOutputFileArg(makeTempFilePath(b, "extracted"));

        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "AddObjectArchive",
                .owner = b,
                .makeFn = make,
            }),
            .source = source,
            .destination = destination,
            .extracted_objs = extracted_objs,
        };

        self.step.dependOn(&ar.step);
        destination.step.dependOn(&self.step);
        destination.step.dependOn(&source.step);

        // Perform the steps in std.Build.Module.linkLibraryOrObject, _except_
        // the bit where we add link objects, because that part we replace in
        // this custom step.
        //
        // If we omit this, then the Zig code in this project will not be able
        // to find headers in @cImport blocks.
        //
        // If we call `linkLibrary` instead of this code, then the build will
        // fail with a linker failure complaining we have duplicate symbols.
        for (destination.root_module.depending_steps.keys()) |compile| {
            compile.step.dependOn(&source.step);
        }
        destination.root_module.include_dirs.append(b.allocator, .{ .other_step = source }) catch @panic("OOM");
        for (destination.root_module.depending_steps.keys()) |compile| {
            source.getEmittedIncludeTree().addStepDependencies(&compile.step);
        }

        return self;
    }

    pub fn make(step: *std.Build.Step, prog_node: std.Progress.Node) anyerror!void {
        _ = prog_node;
        const self: *Self = @fieldParentPtr("step", step);
        self.addObjects() catch |err| {
            return step.fail("Unable to add objects from {s}: {s}", .{
                self.extracted_objs.getPath(self.step.owner), @errorName(err),
            });
        };
    }

    fn addObjects(self: *Self) !void {
        const b = self.step.owner;
        const extracted_objs = self.extracted_objs.getPath(b);
        var dir = try std.fs.openDirAbsolute(extracted_objs, .{ .iterate = true });
        defer dir.close();
        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            std.debug.assert(std.mem.endsWith(u8, entry.name, ".o"));
            const path = try std.fs.path.join(b.allocator, &.{ extracted_objs, entry.name });
            // When running the release build on Linux the unpacked .a files
            // for macos targets have no permission bits set. Zig build then
            // fails with an AccessDenied error. Adding read permissions for
            // these files appears to fix the problem.
            try std.posix.fchmodat(std.fs.cwd().fd, path, std.os.linux.S.IRUSR, 0);
            const generated = try b.allocator.create(std.Build.GeneratedFile);
            generated.* = .{ .step = &self.step, .path = path };
            self.destination.addObjectFile(.{ .generated = .{ .file = generated } });
        }
    }
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
    grammar_objects: [grammars.len]*std.Build.Step.Compile,
    generated_file: std.Build.GeneratedFile,
    module: *std.Build.Module,
    tree_sitter: *std.Build.Dependency,
    output_path: []const u8,

    pub fn create(
        b: *std.Build,
        optimize: std.builtin.OptimizeMode,
        target: std.Build.ResolvedTarget,
    ) *GenerateGrammars {
        const generate_grammars = b.allocator.create(GenerateGrammars) catch @panic("OOM");
        generate_grammars.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "GenerateGrammars",
                .owner = b,
                .makeFn = make,
            }),
            .query_dirs = undefined,
            .grammar_objects = undefined,
            .generated_file = .{ .step = &generate_grammars.step },
            .module = b.createModule(.{
                .root_source_file = .{
                    .generated = .{
                        .file = &generate_grammars.generated_file,
                    },
                },
            }),
            .tree_sitter = b.dependency("tree_sitter", .{
                .target = target,
                .optimize = optimize,
            }),
            .output_path = std.fs.path.join(
                b.allocator,
                &.{ b.makeTempPath(), "generated_grammars.zig" },
            ) catch @panic("OOM"),
        };

        generate_grammars.module.addImport(
            "tree_sitter",
            generate_grammars.tree_sitter.module("tree_sitter"),
        );

        for (grammars, 0..) |grammar, index| {
            // Build grammar
            const dep = b.dependency(grammar.name, .{
                .target = target,
                .optimize = optimize,
            });
            var object = b.addObject(.{
                .name = grammar.name,
                .target = target,
                .optimize = optimize,
            });
            object.root_module.addCSourceFiles(.{
                .root = dep.path("src"),
                .files = grammar.c_source_files,
            });
            object.linkLibC();
            object.root_module.addIncludePath(dep.path("src"));

            generate_grammars.query_dirs[index] = dep.path("queries");
            generate_grammars.grammar_objects[index] = object;
        }

        return generate_grammars;
    }

    pub fn link(self: *GenerateGrammars, root_module: *std.Build.Module) void {
        for (self.grammar_objects) |object| {
            root_module.addObject(object);
        }

        root_module.addImport("tree_sitter", self.tree_sitter.module("tree_sitter"));
        root_module.addImport("generated_grammars", self.module);
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
            \\const ts = @import("tree_sitter");
            \\const Grammar = @This();
            \\
        );
        for (grammars) |grammar| {
            try writer.print(
                "extern fn tree_sitter_{s}() callconv(.C) *ts.Language;\n",
                .{grammar.lang_name()},
            );
        }
        try writer.writeAll(
            \\
            \\name: [:0]const u8,
            \\highlights_query: [*:0]const u8,
            \\injections_query: [*:0]const u8 = "",
            \\locals_query: [*:0]const u8 = "",
            \\ts_language: *const fn () callconv(.C) *ts.Language,
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
    target: std.Build.ResolvedTarget,
    mime: *std.Build.Dependency,
    libcmark_gfm: *std.Build.Dependency,
    tree_sitter_grammars: *GenerateGrammars,
    tree_sitter_core: *std.Build.Dependency,

    fn init(
        b: *std.Build,
        optimize: std.builtin.OptimizeMode,
        target: std.Build.ResolvedTarget,
    ) Deps {
        return .{
            .target = target,
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
            .tree_sitter_core = b.dependency("tree_sitter_core", .{
                .target = target,
                .optimize = optimize,
            }),
        };
    }

    fn install(self: Deps, step: *std.Build.Step.Compile) void {
        _ = AddObjectArchive.create(step, self.target, self.libcmark_gfm.artifact("cmark-gfm"));
        _ = AddObjectArchive.create(step, self.target, self.libcmark_gfm.artifact("cmark-gfm-extensions"));
        _ = AddObjectArchive.create(step, self.target, self.tree_sitter_core.artifact("tree-sitter"));
        step.root_module.addImport("mime", self.mime.module("mime"));
        self.tree_sitter_grammars.link(&step.root_module);
    }
};

// Run `roc build --help` to see the target strings Roc supports.
fn formatTargetForRoc(b: *std.Build, target: std.Build.ResolvedTarget) []const u8 {
    const tag = target.result.os.tag;
    const arch = target.result.cpu.arch;
    return if (tag == .linux and arch == .x86_64)
        "linux-x64"
    else if (tag == .macos and arch == .x86_64)
        "macos-x64"
    else if (tag == .macos and arch == .aarch64)
        "macos-arm64"
    else {
        const triple = target.result.linuxTriple(b.allocator) catch @panic("OOM");
        std.debug.print("target: {s}\n", .{triple});
        @panic("unsupported target");
    };
}

// Run `zig ar --help` to see the archive formats ar supports.
fn formatTargetForAr(b: *std.Build, target: std.Build.ResolvedTarget) []const u8 {
    return if (target.result.isGnu())
        "--format=gnu"
    else if (target.result.isMusl())
        "--format=gnu" // This seems wrong, but nobody complained so :shrug:.
    else if (target.result.isDarwin())
        "--format=darwin"
    else {
        const triple = target.result.linuxTriple(b.allocator) catch @panic("OOM");
        std.debug.print("target: {s}\n", .{triple});
        @panic("unsupported target");
    };
}
