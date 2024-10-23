const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build a fake application for this platform as a library, so we have an
    // object exposing the right functions to compile the host against. The
    // implementation of the fake app will later be replaced with whatever real
    // Roc application we compile.
    const build_libapp = b.addSystemCommand(&.{"roc"});
    build_libapp.addArgs(&.{ "build", "--lib" });
    build_libapp.addFileArg(b.path("platform/libapp.roc"));
    build_libapp.addArg("--output");
    const libapp = build_libapp.addOutputFileArg(makeTempFilePath(b, "libapp.so"));

    const libcmark_gfm = b.dependency("libcmark-gfm", .{
        .target = target,
        .optimize = optimize,
    });

    // Build the host. We're claiming to build an executable here, but I don't
    // think that's exactly right as the artifact produced here is not intended
    // to run on its own.
    const build_dynhost = b.addExecutable(.{
        .name = "jay",
        .root_source_file = b.path("host/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    build_dynhost.addObjectFile(libapp);
    build_dynhost.bundle_compiler_rt = true;
    build_dynhost.linkLibC(); // provides malloc/free/.. used in main.zig
    build_dynhost.linkLibrary(libcmark_gfm.artifact("cmark-gfm"));
    build_dynhost.linkLibrary(libcmark_gfm.artifact("cmark-gfm-extensions"));

    // Build the host again, this time as a library for static linking.
    const build_libhost = b.addStaticLibrary(.{
        .name = "jay",
        .root_source_file = b.path("host/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    build_libhost.bundle_compiler_rt = true;
    build_libhost.linkLibC(); // provides malloc/free/.. used in main.zig
    build_libhost.linkLibrary(libcmark_gfm.artifact("cmark-gfm"));
    build_libhost.linkLibrary(libcmark_gfm.artifact("cmark-gfm-extensions"));

    // Run the Roc surgical linker to tie together our Roc platform and host
    // into something that can be packed up and used as a platform by others.
    const build_host = b.addSystemCommand(&.{"roc"});
    build_host.addArg("preprocess-host");
    build_host.addFileArg(build_dynhost.getEmittedBin());
    build_host.addFileArg(b.path("platform/main.roc"));
    build_host.addFileArg(libapp);

    // Mark all .roc files as dependencies of the two roc commands above. That
    // way zig will know to rerun the roc commands when .roc files change.
    var platform_dir = try std.fs.cwd().openDir("platform", .{ .iterate = true });
    defer platform_dir.close();
    var platform_iter = platform_dir.iterate();
    while (try platform_iter.next()) |roc_file| {
        const roc_path = b.path("platform").path(b, roc_file.name);
        build_libapp.addFileInput(roc_path);
        build_host.addFileInput(roc_path);
    }

    // Present description of roc types from running 'roc glue'. Glue does not
    // currently generate types for Zig, so I only use the output from this
    // command as documentation for hand-writing roc types in zig host code.
    const build_glue = b.addSystemCommand(&.{"roc"});
    build_glue.addArgs(&.{"glue"});
    build_glue.addFileArg(b.path("glue.roc"));
    const build_glue_dir = build_glue.addOutputDirectoryArg(b.makeTempPath());
    build_glue.addFileArg(b.path("platform/main-glue.roc"));

    // We need the host's object files along with any C dependencies to be
    // bundled in a single archive for the legacy linker. The below build
    // step combines archives using a small bash script included in this repo.
    const combine_archive = b.addSystemCommand(&.{"/home/jasper/dev/jay/combine-archives.sh"});
    const combined_archive = combine_archive.addOutputFileArg(makeTempFilePath(b, "combined.a"));
    combine_archive.addFileArg(libcmark_gfm.artifact("cmark-gfm").getEmittedBin());
    combine_archive.addFileArg(libcmark_gfm.artifact("cmark-gfm-extensions").getEmittedBin());
    combine_archive.addFileArg(build_libhost.getEmittedBin());

    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = b.path("platform"),
        .install_dir = .{ .prefix = {} },
        .install_subdir = "platform",
        .include_extensions = &.{"roc"},
    }).step);
    b.getInstallStep().dependOn(&b.addInstallFile(build_dynhost.getEmittedBin(), "platform/dynhost").step);
    b.getInstallStep().dependOn(&b.addInstallFile(combined_archive, "platform/linux-x64.a").step);
    b.getInstallStep().dependOn(&b.addInstallFile(libapp, "platform/libapp.so").step);
    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = build_glue_dir,
        .install_dir = .{ .prefix = {} },
        .install_subdir = "glue",
    }).step);

    // Short-hand for compiling and then running the example application.
    const run_example = b.addSystemCommand(&.{"./example/simple.roc"});
    const run_step = b.step("run", "Run the example");
    run_step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_example.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("host/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_unit_tests.linkLibC(); // provides malloc/free/.. used in main.zig

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
