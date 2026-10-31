//! Command sandbox: allowlist-based execution gating.
const sys = @import("pz_io");
const builtin = @import("builtin");
const std = @import("std");
const agent_config = @import("agent_config.zig");
const path_guard = @import("tools/path_guard.zig");

pub const Err = error{
    UnsupportedPlatform,
    Denied,
    NotFound,
    Io,
    OutOfMemory,
};

const system_exec_roots = [_][]const u8{
    "/bin",
    "/sbin",
    "/private/var/select",
    "/usr/bin",
    "/usr/lib",
    "/usr/libexec",
    "/usr/sbin",
    "/System",
    "/Library/Apple/System",
};

pub const BashPlan = struct {
    argv: []const []const u8,
    cwd: ?[]const u8,
    profile: ?[]u8 = null,
    workspace: ?[]u8 = null,
    bwrap: ?[]u8 = null,
    config_dirs: [6]?[]u8 = @splat(null),

    pub fn deinit(self: *BashPlan, alloc: std.mem.Allocator) void {
        alloc.free(self.argv);
        for (self.config_dirs) |path| if (path) |p| alloc.free(p);
        if (self.profile) |profile| alloc.free(profile);
        if (self.workspace) |workspace| alloc.free(workspace);
        if (self.bwrap) |bwrap| alloc.free(bwrap);
        if (self.cwd) |cwd| alloc.free(cwd);
        self.* = undefined;
    }
};

pub fn prepareBash(
    alloc: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    raw_cwd: ?[]const u8,
    cmd: []const u8,
    escalated: bool,
) Err!BashPlan {
    const root = std.Io.Dir.cwd().realPathFileAlloc(sys.io, ".", alloc) catch |err| return mapFsErr(err);
    defer alloc.free(root);

    var cwd: ?[]const u8 = try alloc.dupe(u8, root);
    errdefer if (cwd) |path| alloc.free(path);
    if (raw_cwd) |path| {
        const base = cwd.?;
        cwd = null;
        alloc.free(base);
        cwd = try resolveCwd(alloc, root, path, !escalated);
    }

    if (escalated) {
        if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.UnsupportedPlatform;
        const argv = try alloc.dupe([]const u8, &.{ "/bin/bash", "--noprofile", "--norc", "-lc", cmd });
        return .{ .argv = argv, .cwd = cwd };
    }

    if (builtin.os.tag == .linux) return prepareLinuxBash(alloc, env, root, cwd.?, cmd);
    if (builtin.os.tag != .macos) return error.UnsupportedPlatform;

    const exec_roots = try collectExecRoots(alloc, env, root);
    defer freeRoots(alloc, exec_roots);

    const profile = try buildBashProfile(alloc, root, cwd.?, exec_roots, env.get("HOME"));
    errdefer alloc.free(profile);

    const argv = try alloc.alloc([]const u8, 8);
    errdefer alloc.free(argv);

    argv[0] = "/usr/bin/sandbox-exec";
    argv[1] = "-p";
    argv[2] = profile;
    argv[3] = "/bin/bash";
    argv[4] = "--noprofile";
    argv[5] = "--norc";
    argv[6] = "-lc";
    argv[7] = cmd;

    return .{
        .argv = argv,
        .cwd = cwd,
        .profile = profile,
    };
}

fn prepareLinuxBash(
    alloc: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    root: []const u8,
    cwd: []const u8,
    cmd: []const u8,
) Err!BashPlan {
    const bwrap = try resolveBwrap(alloc, env);
    errdefer alloc.free(bwrap);
    const workspace = try alloc.dupe(u8, root);
    errdefer alloc.free(workspace);
    var args: std.ArrayList([]const u8) = .empty;
    errdefer args.deinit(alloc);
    try args.appendSlice(alloc, &.{ bwrap, "--die-with-parent", "--unshare-pid", "--ro-bind", "/", "/", "--bind", "/tmp", "/tmp", "--dev", "/dev", "--proc", "/proc" });
    try args.appendSlice(alloc, &.{ "--bind", workspace, workspace });
    var config_dirs: [6]?[]u8 = @splat(null);
    errdefer for (config_dirs) |path| if (path) |p| alloc.free(p);
    var count: usize = 0;
    const bases = [_][]const u8{ root, cwd };
    for (bases, 0..) |base, i| {
        if (i > 0 and std.mem.eql(u8, root, cwd)) continue;
        const dir = path_guard.openDir(base, .{}) catch |err| return mapFsErr(err);
        defer dir.close(sys.io);
        for (agent_config.dirs) |name| {
            dir.createDir(sys.io, name, .fromMode(0o700)) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return mapFsErr(err),
            };
            const path = try std.fs.path.join(alloc, &.{ base, name });
            config_dirs[count] = path;
            count += 1;
            if (path_guard.openDir(path, .{})) |check| {
                check.close(sys.io);
            } else |err| switch (err) {
                error.NotDir => {
                    const file = path_guard.openFile(path, .{}) catch |file_err| return mapFsErr(file_err);
                    defer file.close(sys.io);
                    const stat = file.stat(sys.io) catch |stat_err| return mapFsErr(stat_err);
                    if (stat.kind != .file) return error.Denied;
                },
                else => return mapFsErr(err),
            }
            try args.appendSlice(alloc, &.{ "--ro-bind", path, path });
        }
    }
    try args.appendSlice(alloc, &.{ "--unshare-net", "--chdir", cwd, "--", "/bin/bash", "--noprofile", "--norc", "-lc", cmd });
    const argv = try args.toOwnedSlice(alloc);
    errdefer alloc.free(argv);

    return .{
        .argv = argv,
        .cwd = cwd,
        .workspace = workspace,
        .config_dirs = config_dirs,
        .bwrap = bwrap,
    };
}

fn resolveBwrap(alloc: std.mem.Allocator, env: *const std.process.Environ.Map) Err![]u8 {
    const path_env = env.get("PATH") orelse return error.NotFound;
    var paths = std.mem.splitScalar(u8, path_env, ':');
    while (paths.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = std.fs.path.join(alloc, &.{ dir, "bwrap" }) catch return error.OutOfMemory;
        defer alloc.free(candidate);
        const path_z = std.Io.Dir.cwd().realPathFileAlloc(sys.io, candidate, alloc) catch |err| switch (err) {
            error.FileNotFound, error.NotDir, error.AccessDenied, error.PermissionDenied => continue,
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Io,
        };
        defer alloc.free(path_z);
        return alloc.dupe(u8, path_z) catch return error.OutOfMemory;
    }
    return error.NotFound;
}

fn resolveCwd(alloc: std.mem.Allocator, root: []const u8, path: []const u8, confined: bool) Err![]const u8 {
    const resolved_z = std.Io.Dir.cwd().realPathFileAlloc(sys.io, path, alloc) catch |err| return mapFsErr(err);
    defer alloc.free(resolved_z);
    if (confined and !isWithin(root, resolved_z)) return error.Denied;
    return alloc.dupe(u8, resolved_z) catch return error.OutOfMemory;
}

fn collectExecRoots(
    alloc: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    root: []const u8,
) Err![][]u8 {
    var roots = std.ArrayList([]u8).empty;
    errdefer {
        for (roots.items) |path| alloc.free(path);
        roots.deinit(alloc);
    }

    try pushRoot(alloc, &roots, root);
    for (system_exec_roots) |path| {
        try pushRealOrRawRoot(alloc, &roots, path);
    }

    if (env.get("PATH")) |path_env| {
        var it = std.mem.splitScalar(u8, path_env, ':');
        while (it.next()) |entry| {
            if (entry.len == 0) continue;
            try pushPathRoot(alloc, &roots, entry);
        }
    }

    return try roots.toOwnedSlice(alloc);
}

fn pushPathRoot(alloc: std.mem.Allocator, roots: *std.ArrayList([]u8), path: []const u8) Err!void {
    const abs = std.Io.Dir.cwd().realPathFileAlloc(sys.io, path, alloc) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied, error.PermissionDenied => return,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Io,
    };
    defer alloc.free(abs);

    const norm = execRoot(abs);
    try pushRoot(alloc, roots, norm);
}

fn pushRealOrRawRoot(alloc: std.mem.Allocator, roots: *std.ArrayList([]u8), path: []const u8) Err!void {
    const abs = std.Io.Dir.cwd().realPathFileAlloc(sys.io, path, alloc) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied, error.PermissionDenied => {
            try pushRoot(alloc, roots, path);
            return;
        },
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Io,
    };
    defer alloc.free(abs);

    try pushRoot(alloc, roots, execRoot(abs));
}

fn pushRoot(alloc: std.mem.Allocator, roots: *std.ArrayList([]u8), path: []const u8) Err!void {
    for (roots.items) |cur| {
        if (std.mem.eql(u8, cur, path)) return;
    }
    try roots.append(alloc, try alloc.dupe(u8, path));
}

fn execRoot(path: []const u8) []const u8 {
    return path;
}

fn freeRoots(alloc: std.mem.Allocator, roots: [][]u8) void {
    for (roots) |path| alloc.free(path);
    alloc.free(roots);
}

fn buildBashProfile(
    alloc: std.mem.Allocator,
    root: []const u8,
    cwd: []const u8,
    exec_roots: []const []const u8,
    home: ?[]const u8,
) Err![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    const w = buf.writer(alloc);

    try w.writeAll(
        \\(version 1)
        \\(deny default)
        \\(import "system.sb")
        \\
        \\(allow process-fork)
        \\(allow signal)
        \\
    );
    if (home) |home_path| {
        try w.writeAll(
            \\(deny file-read* file-write* process-exec*
            \\    (require-all
            \\
        );
        try appendSubpath(&buf, alloc, home_path);
        try w.writeAll(
            \\        (require-not
            \\
        );
        try appendSubpath(&buf, alloc, root);
        try w.writeAll(
            \\        )
            \\    )
            \\)
            \\
        );
    }
    try w.writeAll(
        \\(allow file-read* file-write*
        \\
    );
    try appendSubpath(&buf, alloc, root);
    try w.writeAll(
        \\)
        \\
        \\(allow file-read-metadata file-test-existence
        \\
    );
    try appendPathAncestors(&buf, alloc, root);
    try w.writeAll(
        \\)
        \\(deny file-write*
        \\
    );
    const config_bases = [_][]const u8{ root, cwd };
    for (config_bases) |base| {
        for (agent_config.dirs) |name| {
            const path = try std.fs.path.join(alloc, &.{ base, name });
            defer alloc.free(path);
            try appendSubpath(&buf, alloc, path);
        }
    }
    try w.writeAll(
        \\)
        \\
        \\(allow file-read* file-map-executable process-exec*
        \\
    );
    for (exec_roots) |path| {
        try appendSubpath(&buf, alloc, path);
    }
    try w.writeAll(
        \\)
        \\
    );
    return try buf.toOwnedSlice(alloc);
}

fn appendSubpath(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, path: []const u8) Err!void {
    try buf.writer(alloc).writeAll("    (subpath ");
    try appendQuoted(buf, alloc, path);
    try buf.writer(alloc).writeAll(")\n");
}

fn appendPathAncestors(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, path: []const u8) Err!void {
    try buf.writer(alloc).writeAll("    (path-ancestors ");
    try appendQuoted(buf, alloc, path);
    try buf.writer(alloc).writeAll(")\n");
}

fn appendQuoted(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, txt: []const u8) Err!void {
    try buf.append(alloc, '"');
    for (txt) |c| switch (c) {
        '\\', '"' => {
            try buf.append(alloc, '\\');
            try buf.append(alloc, c);
        },
        else => try buf.append(alloc, c),
    };
    try buf.append(alloc, '"');
}

fn isWithin(root: []const u8, path: []const u8) bool {
    if (path.len < root.len) return false;
    if (!std.mem.eql(u8, root, path[0..root.len])) return false;
    if (path.len == root.len) return true;
    return std.fs.path.isSep(path[root.len]);
}

/// Environment variable keys that must be scrubbed before spawning
/// sandboxed children. These may leak credentials or config into
/// untrusted subprocesses.
pub const sensitive_env = [_][]const u8{
    "ANTHROPIC_API_KEY",
    "OPENAI_API_KEY",
    "PZ_API_KEY",
    "PZ_AUTH_TOKEN",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_SESSION_TOKEN",
    "GITHUB_TOKEN",
    "GH_TOKEN",
    "GITLAB_TOKEN",
    "NPM_TOKEN",
    "DOCKER_AUTH_CONFIG",
    "KUBECONFIG",
    "SSH_AUTH_SOCK",
};

/// Remove sensitive keys from env map in-place.
pub fn scrubEnv(env: *std.process.Environ.Map) void {
    for (sensitive_env) |key| {
        _ = env.swapRemove(key);
    }
}

fn mapFsErr(err: anyerror) Err {
    return switch (err) {
        error.FileNotFound, error.NotDir => error.NotFound,
        error.AccessDenied, error.PermissionDenied, error.SymLinkLoop => error.Denied,
        error.OutOfMemory => error.OutOfMemory,
        else => error.Io,
    };
}

test "prepareBash rejects unsupported platforms" {
    if (builtin.os.tag == .macos or builtin.os.tag == .linux) return error.SkipZigTest;
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectError(error.UnsupportedPlatform, prepareBash(std.testing.allocator, &env, null, "true", false));
}

test "prepareBash wraps bash with sandbox-exec and resolves cwd inside workspace" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(sys.io, "sub");

    var cwd_guard = try path_guard.CwdGuard.enter(tmp.dir);
    defer cwd_guard.deinit();

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PATH", "/opt/homebrew/bin:/usr/bin:/bin");

    var plan = try prepareBash(std.testing.allocator, &env, "sub", "printf ok", false);
    defer plan.deinit(std.testing.allocator);

    const root = try tmp.dir.realPathFileAlloc(sys.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const sub = try tmp.dir.realPathFileAlloc(sys.io, "sub", std.testing.allocator);
    defer std.testing.allocator.free(sub);

    try std.testing.expectEqual(@as(usize, 8), plan.argv.len);
    try std.testing.expectEqualStrings("/usr/bin/sandbox-exec", plan.argv[0]);
    try std.testing.expectEqualStrings("-p", plan.argv[1]);
    try std.testing.expectEqualStrings(plan.profile.?, plan.argv[2]);
    try std.testing.expectEqualStrings("/bin/bash", plan.argv[3]);
    try std.testing.expectEqualStrings("--noprofile", plan.argv[4]);
    try std.testing.expectEqualStrings("--norc", plan.argv[5]);
    try std.testing.expectEqualStrings("-lc", plan.argv[6]);
    try std.testing.expectEqualStrings("printf ok", plan.argv[7]);
    try std.testing.expectEqualStrings(sub, plan.cwd.?);
    try std.testing.expect(std.mem.indexOf(u8, plan.profile.?, root) != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.profile.?, "/opt/homebrew") != null);
}

test "prepareBash builds a Linux bubblewrap workspace sandbox" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(sys.io, "sub");
    try tmp.dir.createDirPath(sys.io, "bin");
    var fake_bwrap = try tmp.dir.createFile(sys.io, "bin/bwrap", .{});
    fake_bwrap.close(sys.io);
    const bin = try tmp.dir.realPathFileAlloc(sys.io, "bin", std.testing.allocator);
    defer std.testing.allocator.free(bin);

    var cwd_guard = try path_guard.CwdGuard.enter(tmp.dir);
    defer cwd_guard.deinit();

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PATH", bin);
    const root = try tmp.dir.realPathFileAlloc(sys.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    try env.put("HOME", root);

    var plan = try prepareBash(std.testing.allocator, &env, "sub", "printf ok", false);
    defer plan.deinit(std.testing.allocator);

    const sub = try tmp.dir.realPathFileAlloc(sys.io, "sub", std.testing.allocator);
    defer std.testing.allocator.free(sub);

    try std.testing.expect(std.mem.startsWith(u8, plan.argv[0], bin));
    try std.testing.expect(hasArg(plan.argv, "--ro-bind"));
    try std.testing.expectEqualStrings("--ro-bind", plan.argv[3]);
    try std.testing.expectEqualStrings("/", plan.argv[4]);
    try std.testing.expectEqualStrings("/", plan.argv[5]);
    try std.testing.expect(!hasArg(plan.argv, "/run/pz/workspace"));
    try std.testing.expect(hasArg(plan.argv, root));
    try std.testing.expect(hasArg(plan.argv, "--unshare-net"));
    try std.testing.expectEqualStrings(sub, plan.argv[plan.argv.len - 7]);
    try std.testing.expectEqualStrings("/bin/bash", plan.argv[plan.argv.len - 5]);
    try std.testing.expectEqualStrings("printf ok", plan.argv[plan.argv.len - 1]);
    try std.testing.expectEqualStrings(sub, plan.cwd.?);
    try std.testing.expect(plan.profile == null);
}

fn hasArg(argv: []const []const u8, wanted: []const u8) bool {
    for (argv) |arg| if (std.mem.eql(u8, arg, wanted)) return true;
    return false;
}

test "prepareBash denies cwd escapes" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var outer = std.testing.tmpDir(.{});
    defer outer.cleanup();

    var cwd_guard = try path_guard.CwdGuard.enter(tmp.dir);
    defer cwd_guard.deinit();

    const outer_root = try outer.dir.realPathFileAlloc(sys.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(outer_root);
    try tmp.dir.symLink(sys.io, outer_root, "escape", .{ .is_directory = true });

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");

    try std.testing.expectError(error.Denied, prepareBash(std.testing.allocator, &env, "escape", "true", false));
}

test "scrubEnv removes sensitive keys and preserves others" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PATH", "/usr/bin");
    try env.put("ANTHROPIC_API_KEY", "sk-secret");
    try env.put("OPENAI_API_KEY", "sk-openai");
    try env.put("HOME", "/home/user");
    try env.put("GITHUB_TOKEN", "ghp_tok");

    scrubEnv(&env);

    try std.testing.expect(env.get("ANTHROPIC_API_KEY") == null);
    try std.testing.expect(env.get("OPENAI_API_KEY") == null);
    try std.testing.expect(env.get("GITHUB_TOKEN") == null);
    try std.testing.expectEqualStrings("/usr/bin", env.get("PATH").?);
    try std.testing.expectEqualStrings("/home/user", env.get("HOME").?);
}
