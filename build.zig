const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const build_libapp = b.addSystemCommand(&.{"roc"});
    build_libapp.addArgs(&.{ "build", "--lib" });
    build_libapp.addFileArg(b.path("platform/libapp.roc"));
    build_libapp.addArg("--output");
    const libapp = build_libapp.addOutputFileArg("libapp.so");

    const build_dynhost = b.addExecutable(.{
        .name = "jay",
        .root_source_file = b.path("host/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    build_dynhost.addObjectFile(libapp);
    build_dynhost.linkLibC(); // provides malloc/free/.. used in main.zig

    const build_host = b.addSystemCommand(&.{"roc"});
    build_host.addArg("preprocess-host");
    build_host.addFileArg(build_dynhost.getEmittedBin());
    build_host.addFileArg(b.path("platform/main.roc"));
    build_host.addFileArg(libapp);

    var platform_dir = try std.fs.cwd().openDir("platform", .{ .iterate = true });
    defer platform_dir.close();
    var walker = try platform_dir.walk(b.allocator);
    defer walker.deinit();
    while (try walker.next()) |roc_file| {
        const roc_path = b.path("platform").path(b, roc_file.path);
        build_libapp.addFileInput(roc_path);
        build_host.addFileInput(roc_path);
    }

    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = b.path("platform"),
        .install_dir = .{ .prefix = {} },
        .install_subdir = "platform",
        .include_extensions = &.{"roc"},
    }).step);
    b.getInstallStep().dependOn(&b.addInstallFile(build_dynhost.getEmittedBin(), "platform/dynhost").step);
    b.getInstallStep().dependOn(&b.addInstallFile(libapp, "platform/libapp.so").step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("host/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
