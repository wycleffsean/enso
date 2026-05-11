const std = @import("std");

// const mir_c_flags = &[_][]const u8{
//     "-std=c11",
//     "-D_GNU_SOURCE",
//     "-D_POSIX_C_SOURCE=200809L",
//     "-fno-sanitize=alignment",
//     "-fno-sanitize=undefined",
// };

var mir_c_flags: []const []const u8 = undefined;

pub fn build(b: *std.Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    // dependencies
    const clap = b.dependency("clap", .{});

    const mir_dep = b.dependency("mir", .{});
    const mir = addMirDeps(b, mir_dep, target, optimize);

    var flags: std.ArrayList([]const u8) = .empty;
    defer flags.deinit(b.allocator);
    try flags.appendSlice(b.allocator, &.{
        "-std=c11",
        "-fno-sanitize=alignment",
        "-fno-sanitize=undefined",
    });

    if (target.result.os.tag == .macos) {
        // This opens up the Apple-specific extensions (pthread_jit, etc.)
        // try flags.append(b.allocator, "-D_DARWIN_C_SOURCE");
        // try flags.append(b.allocator, "-DMAP_ANONYMOUS=MAP_ANON");
        try flags.appendSlice(b.allocator, &.{
            "-D_DARWIN_C_SOURCE",
            "-DMAP_ANONYMOUS=MAP_ANON",
            "-DHAVE_ALLOCA_H=1",
        });

        // If you are on Apple Silicon, MIR specifically needs to know
        // it's allowed to use the JIT write-protect toggles.
        if (target.result.cpu.arch == .aarch64) {
            try flags.append(b.allocator, "-DMIR_APPLE_S_SUPPORT");
        }

        // // 1. Enable Darwin-specific features (like MAP_JIT)
        // exe.define_set.add("_DARWIN_C_SOURCE", null);

        // // 2. Map MAP_ANONYMOUS to MAP_ANON (macOS naming)
        // exe.define_set.add("MAP_ANONYMOUS", "MAP_ANON");

        // // 3. Tell MIR we are on Apple Silicon to enable W^X toggling
        // // This enables calls to pthread_jit_write_protect_np
        // exe.define_set.add("MIR_APPLE_S_SUPPORT", null);

        // // 4. Ensure alloca is visible (macOS puts it in alloca.h)
        // exe.define_set.add("HAVE_ALLOCA_H", "1");
    } else {
        // Linux/POSIX defaults
        try flags.append(b.allocator, "-D_GNU_SOURCE");
        try flags.append(b.allocator, "-D_POSIX_C_SOURCE=200809L");
    }

    mir_c_flags = flags.items;

    // MIR probe + codegen
    // We need to do this because mir.h has bitfields
    // which zig translate-c turns into opaque types.
    // It's important that MIR_op_t types can be
    // allocated and returned - so we run a C
    // program which fetches the alignment and size
    // which we can pass to zig
    const mir_probe_exe = b.addExecutable(.{
        .name = "mir-probe",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .ReleaseSmall,
            .link_libc = true,
        }),
    });
    mir_probe_exe.root_module.addCSourceFile(.{
        .file = b.path("src/c/mir_probe.c"),
        .flags = mir_c_flags,
    });
    mir_probe_exe.root_module.addIncludePath(mir_dep.path("."));
    const mir_probe_run = b.addRunArtifact(mir_probe_exe);
    const mir_probe_out = mir_probe_run.captureStdOut(.{});
    const mir_probe_gen = b.addWriteFiles();
    const mir_abi_file = mir_probe_gen.add("mir_abi.zig", "");
    // TODO: this copy is lame, there's gotta
    // be a better method
    const copy_mir_abi = b.addSystemCommand(&.{"cp"});
    copy_mir_abi.addFileArg(mir_probe_out); // source file
    copy_mir_abi.addFileArg(mir_abi_file); // destination file
    copy_mir_abi.step.dependOn(&mir_probe_run.step);

    // enso exe
    const exe = b.addExecutable(.{
        .name = "enso",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(exe);

    exe.root_module.addImport("clap", clap.module("clap"));
    exe.root_module.linkLibrary(mir.mir_core);
    exe.root_module.linkLibrary(mir.c2mir);
    exe.root_module.linkLibrary(mir.mir2c);

    exe.root_module.addIncludePath(mir_dep.path("."));
    exe.root_module.addIncludePath(mir_dep.path("c2mir"));
    exe.root_module.addIncludePath(mir_dep.path("mir2c"));
    exe.root_module.addAnonymousImport("mir_abi", .{
        .root_source_file = mir_abi_file,
    });
    exe.step.dependOn(&copy_mir_abi.step);

    const mir_mod = b.addModule("mir", .{ .root_source_file = b.path("src/mir.zig") });
    exe.root_module.addImport("mir", mir_mod);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // MIR example

    const mir_exe = b.addExecutable(.{
        .name = "mir-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mir-example.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    mir_exe.root_module.linkLibrary(mir.mir_core);
    mir_exe.root_module.linkLibrary(mir.c2mir);
    mir_exe.root_module.linkLibrary(mir.mir2c);

    mir_exe.root_module.addIncludePath(mir_dep.path("."));
    mir_exe.root_module.addIncludePath(mir_dep.path("c2mir"));
    mir_exe.root_module.addIncludePath(mir_dep.path("mir2c"));
    mir_exe.root_module.addImport("mir", mir_mod);
    mir_exe.root_module.addAnonymousImport("mir_abi", .{
        .root_source_file = mir_abi_file,
    });
    mir_exe.step.dependOn(&copy_mir_abi.step);

    b.installArtifact(mir_exe);
    const run_mir_cmd = b.addRunArtifact(mir_exe);
    run_mir_cmd.step.dependOn(b.getInstallStep());
    const run_mir_step = b.step("run-mir-example", "Run the mir example");
    exe.root_module.addAnonymousImport("mir_abi", .{
        .root_source_file = mir_abi_file,
    });
    run_mir_step.dependOn(&run_mir_cmd.step);

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
    const python_examples_mod = try pythonDisExamples(b);
    python_examples_mod.addImport("enso", unit_tests.root_module);
    unit_tests.root_module.addImport("disassembled_examples", python_examples_mod);
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
    // python_run.stdio_limit = .limited(20 * 1024 * 1024); // 20MB
    return python_run;
}

fn collectPythonFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    dir_path: []const u8,
    paths: *std.ArrayList([]const u8),
) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });

        switch (entry.kind) {
            .file => {
                if (std.mem.endsWith(u8, entry.name, ".py")) {
                    try paths.append(allocator, full_path);
                }
            },
            .directory => {
                // Recurse into subdirectory
                var subdir = try dir.openDir(io, entry.name, .{ .iterate = true });
                defer subdir.close(io);
                try collectPythonFiles(allocator, io, subdir, full_path, paths);
            },
            else => {},
        }
    }
}

// We create a separate module for this test support content.  It is generated during the build
// and all relevant files are copied into the zig cache.  It codegens a file/module called
// disassembled_examples
fn pythonDisExamples(b: *std.Build) !*std.Build.Module {
    var arena = std.heap.ArenaAllocator.init(b.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = b.graph.io;
    const wf = b.addWriteFiles();

    const python_run = generateZigFromPython(b, "python/disassemble_examples_to_zig.py");

    var paths: std.ArrayList([]const u8) = .empty;
    var root_dir = try std.Io.Dir.cwd().openDir(io, "python/examples", .{ .iterate = true });
    defer root_dir.close(io);

    try collectPythonFiles(allocator, io, root_dir, "python/examples", &paths);

    for (paths.items) |path| {
        python_run.addFileArg(b.path(path));
        // copy python examples into the zig cache. We truncate the
        // path part therefore all example names must be unique
        const file_name = std.fs.path.basename(path);
        _ = wf.addCopyFile(b.path(path), file_name);
    }

    const python_dis_examples = python_run.addOutputFileArg("disassembled_examples.zig");
    const zig_file_in_wf = wf.addCopyFile(python_dis_examples, "disassembled_examples.zig");
    const python_examples_mod = b.addModule("disassembled_examples", .{
        .root_source_file = zig_file_in_wf,
    });
    return python_examples_mod;
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

    // mir_core (static)
    const mir_core = b.addLibrary(.{
        .name = "mir_core",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    mir_core.root_module.sanitize_c = .off;
    mir_core.root_module.addIncludePath(mir_root);

    mir_core.root_module.addCSourceFile(.{
        .file = b.path("src/c/mir_unity.c"),
        .flags = mir_c_flags,
    });
    mir_core.root_module.addCSourceFile(.{
        .file = mir_dep.path("mir-gen.c"),
        .flags = mir_c_flags,
    });

    // c2mir (static)
    const c2mir = b.addLibrary(.{
        .name = "c2mir",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    c2mir.root_module.sanitize_c = .off;
    c2mir.root_module.addIncludePath(mir_root);
    c2mir.root_module.addIncludePath(mir_dep.path("c2mir"));

    addCFilesFromDirExcluding(
        b,
        c2mir,
        mir_dep.path("c2mir"),
        mir_c_flags,
        &[_][]const u8{"c2mir-driver.c"},
    );

    // mir2c (static)
    const mir2c = b.addLibrary(.{
        .name = "mir2c",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    mir2c.root_module.sanitize_c = .off;
    mir2c.root_module.addIncludePath(mir_root);
    mir2c.root_module.addIncludePath(mir_dep.path("mir2c"));

    addCFilesFromDirExcluding(
        b,
        mir2c,
        mir_dep.path("mir2c"),
        mir_c_flags,
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
    const io = b.graph.io;

    const abs_dir = dir_path.getPath(b);
    var dir = std.Io.Dir.openDirAbsolute(io, abs_dir, .{ .iterate = true }) catch |e| {
        std.debug.panic("openDirAbsolute({s}) failed: {any}", .{ abs_dir, e });
    };
    defer dir.close(io);

    var it = dir.iterate();
    var files: std.ArrayList([]const u8) = .empty;

    while (it.next(io) catch |e| {
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
        files.append(arena, arena.dupe(u8, ent.name) catch @panic("oom")) catch @panic("oom");
    }

    lib.root_module.addCSourceFiles(.{
        .root = dir_path,
        .files = files.items,
        .flags = c_flags,
    });
}
