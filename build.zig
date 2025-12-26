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

    const mir_dep = b.dependency("mir", .{});
    const mir = addMirDeps(b, mir_dep, target, optimize);
    exe.linkLibrary(mir.mir_core);
    exe.linkLibrary(mir.c2mir);
    exe.linkLibrary(mir.mir2c);
    exe.linkLibC();

    exe.addIncludePath(mir_dep.path("."));
    exe.addIncludePath(mir_dep.path("c2mir"));
    exe.addIncludePath(mir_dep.path("mir2c"));

    const mir_mod = b.addModule("mir", .{ .root_source_file = b.path("src/mir.zig") });
    exe.root_module.addImport("mir", mir_mod);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Testing

    // const test_filters = b.option([]const []const u8, "test-filter", "Skip tests that do not match any filter") orelse .{};

    const unit_tests = b.addTest(.{
        .name = "enso_tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
        // .filters = test_filters,
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
    paths: *std.ArrayList([]const u8),
) !void {
    var it = dir.iterate();
    while (try it.next()) |entry| {
        const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });

        switch (entry.kind) {
            .file => {
                if (std.mem.endsWith(u8, entry.name, ".py")) {
                    try paths.append(allocator, full_path);
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

    var paths: std.ArrayList([]const u8) = .{};

    var root_dir = try std.fs.cwd().openDir("src/test/examples", .{ .iterate = true });
    defer root_dir.close();

    try collectPythonFiles(allocator, root_dir, "src/test/examples", &paths);

    for (paths.items) |path| {
        python_run.addFileArg(b.path(path));
    }

    return b.addInstallFile(python_run.captureStdOut(), "../src/test/disassembled_examples.zig");
}

const MirArtifacts = struct {
    mir_core: *std.Build.Step.Compile,
    c2mir: *std.Build.Step.Compile,
    mir2c: *std.Build.Step.Compile,
};

fn addMirDeps(
    b: *std.Build,
    mir_dep: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) MirArtifacts {
    const mir_root = mir_dep.path(".");

    const c_flags = &[_][]const u8{
        "-std=c11",
        "-D_POSIX_C_SOURCE=200809L",
        "-D_GNU_SOURCE",
        // "-DMIR_x86_64",
    };

    const mir_core = b.addStaticLibrary(.{
        .name = "mir_core",
        .target = target,
        .optimize = optimize,
    });
    mir_core.linkLibC();
    mir_core.addIncludePath(mir_root);

    mir_core.addCSourceFiles(.{
        .root = mir_root,
        .files = &[_][]const u8{
            "mir.c",
            "mir-gen.c",
            // "mir-interp.c", // included by mir.c, not a separate translation unit
            "mir-alloc-default.c",
            "mir-code-alloc-default.c",
        },
        .flags = c_flags,
    });

    // c2mir
    const c2mir = b.addStaticLibrary(.{
        .name = "c2mir",
        .target = target,
        .optimize = optimize,
    });
    c2mir.linkLibC();
    c2mir.addIncludePath(mir_root);
    c2mir.addIncludePath(mir_dep.path("c2mir"));

    addCFilesFromDirExcluding(
        b,
        c2mir,
        mir_dep.path("c2mir"),
        c_flags,
        &[_][]const u8{"c2mir-driver.c"},
    );

    // mir2c
    const mir2c = b.addStaticLibrary(.{
        .name = "mir2c",
        .target = target,
        .optimize = optimize,
    });
    mir2c.linkLibC();
    mir2c.addIncludePath(mir_root);
    mir2c.addIncludePath(mir_dep.path("mir2c"));

    addCFilesFromDirExcluding(
        b,
        mir2c,
        mir_dep.path("mir2c"),
        c_flags,
        &[_][]const u8{
            // add exclusions if there’s a driver main()
        },
    );

    return .{ .mir_core = mir_core, .c2mir = c2mir, .mir2c = mir2c };
}

fn addCFilesFromDirExcluding(
    b: *std.Build,
    lib: *std.Build.Step.Compile,
    dir_path: std.Build.LazyPath,
    c_flags: []const []const u8,
    exclude: []const []const u8,
) void {
    // Build scripts run on the host, so we can walk the directory at build time.
    const arena = b.allocator;

    const abs_dir = dir_path.getPath(b);
    var dir = std.fs.openDirAbsolute(abs_dir, .{ .iterate = true }) catch |e| {
        std.debug.panic("openDirAbsolute({s}) failed: {any}", .{ abs_dir, e });
    };
    defer dir.close();

    var it = dir.iterate();
    var files = std.ArrayList([]const u8).init(arena);

    while (it.next() catch |e| {
        std.debug.panic("iterate({s}) failed: {any}", .{ abs_dir, e });
    }) |ent| {
        if (ent.kind != .file) continue;
        if (!std.mem.endsWith(u8, ent.name, ".c")) continue;

        var skip = false;
        for (exclude) |ex| {
            if (std.mem.eql(u8, ent.name, ex)) {
                skip = true;
                break;
            }
        }
        if (skip) continue;

        // Store relative-to-dir filenames (Build API wants relative to .root)
        files.append(arena.dupe(u8, ent.name) catch @panic("oom")) catch @panic("oom");
    }

    lib.addCSourceFiles(.{
        .root = dir_path,
        .files = files.items,
        .flags = c_flags,
    });
}
