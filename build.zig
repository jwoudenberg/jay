const std = @import("std");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

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

    buildDynhost(b, optimize, target, roc_paths.items);
    buildLegacy(b, optimize, target);
    buildGlue(b);
    buildDocs(b, roc_paths.items);
    runTests(b, optimize, target);

    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = b.path("platform"),
        .install_dir = .{ .prefix = {} },
        .install_subdir = "platform",
        .include_extensions = &.{"roc"},
    }).step);
}

fn buildDynhost(
    b: *std.Build,
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

    const libcmark_gfm = b.dependency("libcmark-gfm", .{
        .target = target,
        .optimize = optimize,
    });

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
    dynhost.addObjectFile(libapp_so);
    dynhost.linkLibrary(libcmark_gfm.artifact("cmark-gfm"));
    dynhost.linkLibrary(libcmark_gfm.artifact("cmark-gfm-extensions"));
    dynhost.root_module.addImport("mime", b.dependency("mime", .{
        .target = target,
        .optimize = optimize,
    }).module("mime"));

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
    optimize: std.builtin.OptimizeMode,
    target: std.Build.ResolvedTarget,
) void {
    const libcmark_gfm = b.dependency("libcmark-gfm", .{
        .target = target,
        .optimize = optimize,
    });

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
    libhost.linkLibrary(libcmark_gfm.artifact("cmark-gfm"));
    libhost.linkLibrary(libcmark_gfm.artifact("cmark-gfm-extensions"));
    libhost.root_module.addImport("mime", b.dependency("mime", .{
        .target = target,
        .optimize = optimize,
    }).module("mime"));

    // We need the host's object files along with any C dependencies to be
    // bundled in a single archive for the legacy linker. The below build
    // step combines archives using a small bash script included in this repo.
    const combine_archive = b.addSystemCommand(&.{"build/combine-archives.sh"});
    const combined_archive = combine_archive.addOutputFileArg(makeTempFilePath(b, "combined.a"));
    combine_archive.addFileArg(libcmark_gfm.artifact("cmark-gfm").getEmittedBin());
    combine_archive.addFileArg(libcmark_gfm.artifact("cmark-gfm-extensions").getEmittedBin());
    combine_archive.addFileArg(libhost.getEmittedBin());

    b.getInstallStep().dependOn(&b.addInstallFile(combined_archive, "platform/linux-x64.a").step);
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
) void {
    const docs = b.addSystemCommand(&.{"roc"});
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
}

fn runTests(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    target: std.Build.ResolvedTarget,
) void {
    const libcmark_gfm = b.dependency("libcmark-gfm", .{
        .target = target,
        .optimize = optimize,
    });

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("host/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_unit_tests.linkLibC(); // provides malloc/free/.. used in main.zig
    exe_unit_tests.root_module.addImport("mime", b.dependency("mime", .{
        .target = target,
        .optimize = optimize,
    }).module("mime"));
    exe_unit_tests.linkLibrary(libcmark_gfm.artifact("cmark-gfm"));
    exe_unit_tests.linkLibrary(libcmark_gfm.artifact("cmark-gfm-extensions"));

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
