const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "enso",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Testing

    const test_filter = b.option([]const u8, "test-filter", "Skip tests that do not match any filter") orelse null;

    const unit_tests = b.addTest(.{
        .name = "enso_tests",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
        .filter = test_filter,
    });
    unit_tests.step.dependOn(&pythonDisExamples(b).step);
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // TODO: this worked with the prior build API, and is useful for
    //   debugging
    // const tests_exe = b.addTestExe("blithe_tests", "src/main.zig");
    // tests_exe.setTarget(target);
    // tests_exe.setBuildMode(mode);
    // tests_exe.install();
}

fn generateZigFromPython(b: *std.build.Builder, script_path: []const u8) *std.Build.Step.Run {
    const python_run = b.addSystemCommand(&.{"python"});
    python_run.addFileArg(.{ .path = script_path });
    return python_run;
}

fn pythonDisExamples(b: *std.build.Builder) *std.Build.Step.InstallFile {
    const python_run = generateZigFromPython(b, "python/disassemble_examples_to_zig.py");
    var path_buf: [255][std.fs.MAX_PATH_BYTES]u8 = undefined;
    var dir = std.fs.cwd().openIterableDir("src/test/examples", .{}) catch unreachable;
    defer dir.close();
    var iter = dir.iterate();
    var i: usize = 0;
    while (iter.next() catch unreachable) |entry| {
        // this will lead to a nasty error once we exceed 255 examples :P
        const path = std.fmt.bufPrint(&path_buf[i], "src/test/examples/{s}", .{entry.name}) catch unreachable;
        python_run.addFileArg(std.Build.LazyPath.relative(path));
        i += 1;
    }
    return b.addInstallFile(python_run.captureStdOut(), "../src/test/disassembled_examples.zig");
}
