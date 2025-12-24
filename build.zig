const std = @import("std");

pub fn build(b: *std.Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "enso",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    // dependencies
    const clap = b.dependency("clap", .{});
    exe.root_module.addImport("clap", clap.module("clap"));

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Testing

    // const test_filter = b.option([]const u8, "test-filter", "Skip tests that do not match any filter") orelse null;

    const unit_tests = b.addTest(.{
        .name = "enso_tests",
        .root_module = exe.root_module,
    });
    const python_examples = try pythonDisExamples(b);
    unit_tests.step.dependOn(&python_examples.step);
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

fn generateZigFromPython(b: *std.Build, script_path: []const u8) *std.Build.Step.Run {
    const python_run = b.addSystemCommand(&.{"python"});
    python_run.addFileArg(b.path(script_path));
    python_run.max_stdio_size = 20 * 1024 * 1024; // 20MB
    return python_run;
}

fn collectPythonFiles(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    dir_path: []const u8,
    paths: *std.array_list.Managed([]const u8),
) !void {
    var it = dir.iterate();
    while (try it.next()) |entry| {
        const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });

        switch (entry.kind) {
            .file => {
                if (std.mem.endsWith(u8, entry.name, ".py")) {
                    try paths.append(full_path);
                }
            },
            .directory => {
                // Recurse into subdirectory
                var subdir = try dir.openDir(entry.name, .{ .iterate = true });
                defer subdir.close();
                try collectPythonFiles(allocator, subdir, full_path, paths);
            },
            else => {},
        }
    }
}

fn pythonDisExamples(b: *std.Build) !*std.Build.Step.InstallFile {
    var arena = std.heap.ArenaAllocator.init(b.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const python_run = generateZigFromPython(b, "python/disassemble_examples_to_zig.py");

    var paths = std.array_list.Managed([]const u8).init(allocator);

    var root_dir = try std.fs.cwd().openDir("src/test/examples", .{ .iterate = true });
    defer root_dir.close();

    try collectPythonFiles(allocator, root_dir, "src/test/examples", &paths);

    for (paths.items) |path| {
        python_run.addFileArg(b.path(path));
    }

    return b.addInstallFile(python_run.captureStdOut(), "../src/test/disassembled_examples.zig");
}
