const std = @import("std");
const pkg = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dep_opt = .{
        .target = target,
        .optimize = optimize,
    };
    const policy_pk_hex = b.option(
        []const u8,
        "policy-pk-hex",
        "Trusted Ed25519 public key for policy bundles",
    ) orelse "2d6f7455d97b4a3a10d7293909d1a4f2058cb9a370e43fa8154bb280db839083";
    // zcheck's package build still shells out to git; import the module directly.
    const zcheck_mod = depMod(b, "zcheck", "src/zcheck.zig", target, optimize);
    const ohsnap_mod = if (b.lazyDependency("ohsnap", dep_opt)) |d| d.module("ohsnap") else null;

    // Build options: version, VCS hash, changelog
    const options = b.addOptions();
    const test_options = b.addOptions();

    const opts_pair = .{ options, test_options };
    addSharedOpt(opts_pair, []const u8, "version", pkg.version);
    const vcs_hash = std.mem.trimEnd(u8, b.run(&.{ "git", "rev-parse", "--short=12", "HEAD" }), "\n\r ");
    addSharedOpt(opts_pair, []const u8, "git_hash", vcs_hash);

    const is_release = switch (optimize) {
        .Debug => false,
        .ReleaseSafe, .ReleaseFast, .ReleaseSmall => true,
    };

    if (is_release) {
        // State tracker key: version for release (matches ## [ver] headings).
        addSharedOpt(opts_pair, []const u8, "build_id", pkg.version);
        addSharedOpt(opts_pair, []const u8, "changelog", @embedFile("CHANGELOG.md"));
    } else {
        // State tracker key: hash for dev (matches line-start in VCS log).
        addSharedOpt(opts_pair, []const u8, "build_id", vcs_hash);

        const vcs_log_raw = b.run(&.{ "git", "log", "-50", "--abbrev=12", "--format=%h %s" });
        const vcs_log = std.mem.trimEnd(u8, vcs_log_raw, "\n\r ");
        addSharedOpt(opts_pair, []const u8, "changelog", vcs_log);
    }
    addSharedOpt(opts_pair, []const u8, "policy_pk_hex", policy_pk_hex);

    const io_mod = b.createModule(.{
        .root_source_file = b.path("src/io.zig"),
        .target = target,
        .optimize = optimize,
    });

    const core_agent_mod = b.createModule(.{
        .root_source_file = b.path("src/core/agent.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    core_agent_mod.addImport("pz_io", io_mod);

    const exe = b.addExecutable(.{
        .name = "pz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .link_libc = true,
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("pz_io", io_mod);
    exe.root_module.addOptions("build_options", options);
    b.installArtifact(exe);
    test_options.addOptionPath("pz_bin_path", exe.getEmittedBin());

    const build_step = b.step("build", "Build the executable");
    build_step.dependOn(&exe.step);
    b.default_step.dependOn(build_step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.stdio = .inherit;
    const run_step = b.step("run", "Run pz");
    run_step.dependOn(&run_cmd.step);

    const agent_exit_harness = b.addExecutable(.{
        .name = "agent-exit-harness",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test/agent_exit_harness.zig"),
            .link_libc = true,
            .target = target,
            .optimize = optimize,
        }),
    });
    agent_exit_harness.root_module.addImport("pz_io", io_mod);
    agent_exit_harness.root_module.addImport("core_agent", core_agent_mod);
    const agent_child_harness = b.addExecutable(.{
        .name = "agent-child-harness",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test/agent_child_harness.zig"),
            .link_libc = true,
            .target = target,
            .optimize = optimize,
        }),
    });
    agent_child_harness.root_module.addImport("pz_io", io_mod);
    agent_child_harness.root_module.addImport("core_agent", core_agent_mod);
    test_options.addOptionPath("agent_child_harness_path", agent_child_harness.getEmittedBin());

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    configTestMod(exe_tests.root_module, ohsnap_mod, zcheck_mod, null);
    const run_exe_tests = b.addRunArtifact(exe_tests);
    run_exe_tests.setEnvironmentVariable("PZ_DISABLE_BROWSER_OPEN", "1");

    const suite_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .link_libc = true,
            .target = target,
            .optimize = optimize,
        }),
    });
    suite_tests.root_module.addImport("pz_io", io_mod);
    configTestMod(suite_tests.root_module, ohsnap_mod, zcheck_mod, test_options);
    const run_suite_tests = b.addRunArtifact(suite_tests);
    run_suite_tests.setEnvironmentVariable("PZ_DISABLE_BROWSER_OPEN", "1");

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_suite_tests.step);
    const run_agent_exit_version = b.addRunArtifact(agent_exit_harness);
    run_agent_exit_version.addArg("version");
    run_agent_exit_version.expectExitCode(78);
    test_step.dependOn(&run_agent_exit_version.step);
    const run_agent_exit_other = b.addRunArtifact(agent_exit_harness);
    run_agent_exit_other.addArg("other");
    run_agent_exit_other.expectExitCode(0);
    test_step.dependOn(&run_agent_exit_other.step);
    const run_agent_child_hello = b.addRunArtifact(agent_child_harness);
    run_agent_child_hello.addArgs(&.{
        "hello",
        "agent-child",
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        "1", // RPC fd: use stdout for standalone hello test
    });
    run_agent_child_hello.expectExitCode(0);
    test_step.dependOn(&run_agent_child_hello.step);

    const perf_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/perf_tests.zig"),
            .link_libc = true,
            .target = target,
            .optimize = optimize,
        }),
    });
    perf_tests.root_module.addImport("pz_io", io_mod);
    configTestMod(perf_tests.root_module, ohsnap_mod, zcheck_mod, test_options);
    const run_perf_tests = b.addRunArtifact(perf_tests);
    run_perf_tests.setEnvironmentVariable("PZ_DISABLE_BROWSER_OPEN", "1");
    const perf_step = b.step("perf", "Run performance budget tests");
    perf_step.dependOn(&run_perf_tests.step);

    const check_step = b.step("check", "Compile executable and tests");
    check_step.dependOn(&exe.step);
    check_step.dependOn(&agent_exit_harness.step);
    check_step.dependOn(&exe_tests.step);
    check_step.dependOn(&suite_tests.step);
    check_step.dependOn(&perf_tests.step);
}

fn addSharedOpt(
    opts: struct { *std.Build.Step.Options, *std.Build.Step.Options },
    comptime T: type,
    key: []const u8,
    value: T,
) void {
    opts[0].addOption(T, key, value);
    opts[1].addOption(T, key, value);
}

fn configTestMod(
    mod: *std.Build.Module,
    ohsnap_mod: ?*std.Build.Module,
    zcheck_mod: *std.Build.Module,
    build_options: ?*std.Build.Step.Options,
) void {
    if (ohsnap_mod) |m| mod.addImport("ohsnap", m);
    mod.addImport("zcheck", zcheck_mod);
    if (build_options) |opts| mod.addOptions("build_options", opts);
}

fn depMod(
    b: *std.Build,
    name: []const u8,
    sub_path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = .{ .cwd_relative = b.fmt("{s}/{s}", .{ depRoot(b, name), sub_path }) },
        .target = target,
        .optimize = optimize,
    });
}

fn depRoot(b: *std.Build, name: []const u8) []const u8 {
    const pkgs = @import("root").dependencies.packages;

    for (b.available_deps) |dep| {
        const dep_name, const dep_hash = dep;
        if (!std.mem.eql(u8, dep_name, name)) continue;

        const info = @typeInfo(pkgs).@"struct";
        if (@hasField(@TypeOf(info), "decls")) {
            inline for (info.decls) |decl| {
                if (std.mem.eql(u8, dep_hash, decl.name)) {
                    return @field(pkgs, decl.name).build_root;
                }
            }
        } else {
            inline for (info.decl_names) |decl_name| {
                if (std.mem.eql(u8, dep_hash, decl_name)) {
                    return @field(pkgs, decl_name).build_root;
                }
            }
        }
        unreachable;
    }

    std.debug.panic("missing dependency '{s}'", .{name});
}
