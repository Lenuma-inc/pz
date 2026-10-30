//! AGENTS.md context discovery and loading.
const sys = @import("pz_io");
const std = @import("std");
const policy = @import("policy.zig");
const prov_api = @import("providers/api.zig");
const trust = @import("context_trust.zig");
pub const Approval = trust.Approval;
const path_guard = @import("tools/path_guard.zig");

fn chdirPath(path: []const u8) !void {
    const path_z = try std.posix.toPosixPath(path);
    if (std.c.chdir(&path_z) != 0) return std.posix.unexpectedErrno(std.posix.errno(-1));
}

/// Maximum total bytes for assembled AGENTS.md context.
/// Files are included in discovery order; once the budget is exhausted,
/// remaining files are truncated with a marker.
pub const max_context_bytes: usize = 256 * 1024;

/// Discover and load AGENTS.md context files.
/// Searches global dir, then walks cwd upward to root.
/// Returns concatenated content with section headers.
/// Total output is capped at `max_context_bytes`; excess is truncated.
pub fn load(alloc: std.mem.Allocator, io: std.Io, home: ?[]const u8) !?[]u8 {
    return loadWithApproval(alloc, io, home, null);
}

pub fn loadWithApproval(alloc: std.mem.Allocator, io: std.Io, home: ?[]const u8, approval: ?Approval) !?[]u8 {
    const paths = try discoverPaths(alloc, io, home);
    defer {
        for (paths) |path| alloc.free(path);
        alloc.free(paths);
    }
    var parts: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (parts.items) |part| alloc.free(part);
        parts.deinit(alloc);
    }
    for (paths) |path| {
        if (try readFile(alloc, std.fs.path.dirname(path).?, "AGENTS.md", home, approval)) |content| {
            errdefer alloc.free(content);
            try parts.append(alloc, content);
        }
    }
    return assembleParts(alloc, parts.items);
}

const truncation_marker = "\n\n[context truncated: budget exceeded]\n";

fn assembleParts(alloc: std.mem.Allocator, parts: []const []u8) !?[]u8 {
    return assemblePartsWithBudget(alloc, parts, max_context_bytes);
}

fn assemblePartsWithBudget(alloc: std.mem.Allocator, parts: []const []u8, budget: usize) !?[]u8 {
    if (parts.len == 0) return null;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);

    for (parts, 0..) |p, i| {
        const sep_len: usize = if (i > 0) 2 else 0;
        const needed = sep_len + p.len;

        if (buf.items.len + needed > budget) {
            // Fit what we can, then truncate
            const remaining = budget -| (buf.items.len + sep_len + truncation_marker.len);
            if (sep_len > 0 and buf.items.len + sep_len <= budget) {
                try buf.appendSlice(alloc, "\n\n");
            }
            if (remaining > 0 and remaining <= p.len) {
                try buf.appendSlice(alloc, p[0..remaining]);
            }
            try buf.appendSlice(alloc, truncation_marker);
            break;
        }

        if (i > 0) {
            try buf.appendSlice(alloc, "\n\n");
        }
        try buf.appendSlice(alloc, p);
    }

    return try buf.toOwnedSlice(alloc);
}

/// Returns list of discovered context file paths (for startup display).
pub fn discoverPaths(alloc: std.mem.Allocator, io: std.Io, home: ?[]const u8) ![][]u8 {
    if ((try loadPolicyLock(alloc, io, home)).context) return try alloc.alloc([]u8, 0);

    var paths: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (paths.items) |p| alloc.free(p);
        paths.deinit(alloc);
    }

    if (try globalDir(alloc, home)) |gdir| {
        defer alloc.free(gdir);
        if (try findFile(alloc, gdir)) |p| try paths.append(alloc, p);
    }

    try walkAncestry(alloc, &paths, struct {
        fn cb(a: std.mem.Allocator, dir: []const u8, list: *std.ArrayListUnmanaged([]u8)) !void {
            if (try findFile(a, dir)) |p| try list.append(a, p);
        }
    }.cb);

    return try paths.toOwnedSlice(alloc);
}

/// Walk cwd ancestry (cwd, parent, grandparent, ...) calling `cb` for each dir.
fn walkAncestry(
    alloc: std.mem.Allocator,
    ctx: anytype,
    cb: *const fn (std.mem.Allocator, []const u8, @TypeOf(ctx)) anyerror!void,
) !void {
    const cwd = (try realCwdAlloc(alloc)) orelse return;
    defer alloc.free(cwd);

    var dir: []const u8 = cwd;
    while (true) {
        try cb(alloc, dir, ctx);
        dir = parent(dir) orelse break;
    }
}

fn findFile(alloc: std.mem.Allocator, dir: []const u8) !?[]u8 {
    if (!hasSecureFile(dir, "AGENTS.md")) return null;
    return try std.fmt.allocPrint(alloc, "{s}/AGENTS.md", .{dir});
}

/// Returns the global config dir (~/.pz), or null when HOME is unset/invalid.
fn globalDir(alloc: std.mem.Allocator, home: ?[]const u8) !?[]u8 {
    const h = home orelse return null;
    return try std.fmt.allocPrint(alloc, "{s}/.pz", .{h});
}

fn loadPolicyLock(alloc: std.mem.Allocator, io: std.Io, home: ?[]const u8) !policy.Lock {
    const cwd = (try realCwdAlloc(alloc)) orelse return .{};
    defer alloc.free(cwd);
    return policy.loadLock(alloc, io, cwd, home);
}

/// Read and wrap a context file from `dir/name`.
/// Returns null when the file is genuinely absent (FileNotFound / symlink rejected).
/// Returns error for I/O failures (permission denied, corrupt data, OOM).
fn readFile(alloc: std.mem.Allocator, dir: []const u8, name: []const u8, home: ?[]const u8, approval: ?Approval) !?[]u8 {
    const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name });
    defer alloc.free(path);

    var abs_dir = std.Io.Dir.openDirAbsolute(sys.io, dir, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    defer abs_dir.close(sys.io);

    var file = path_guard.openFileInDir(abs_dir, name, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound, error.SymLinkLoop, error.NotDir => return null,
        else => return err,
    };
    defer file.close(sys.io);

    const raw = try readAllAlloc(file, alloc, 1024 * 1024);
    if (raw.len == 0) {
        alloc.free(raw);
        return null;
    }

    const allowed = trust.allow(alloc, home, path, raw, approval) catch |err| {
        alloc.free(raw);
        return err;
    };
    if (!allowed) {
        alloc.free(raw);
        return null;
    }

    // Review and hashing use raw bytes; only rendering/provider serialization is lossy.
    const content = if (std.unicode.Utf8View.init(raw)) |_| raw else |_| blk: {
        const san = @import("utf8.zig").sanitizeLossyAlloc(alloc, raw) catch |err| {
            alloc.free(raw);
            return err;
        };
        alloc.free(raw);
        break :blk san;
    };
    defer alloc.free(content);
    const wrapped = try prov_api.wrapUntrustedNamed(alloc, "context-file", path, content);
    defer alloc.free(wrapped);
    return try std.fmt.allocPrint(alloc, "## {s}\n\n{s}", .{ path, wrapped });
}

fn readAllAlloc(file: std.Io.File, alloc: std.mem.Allocator, max_bytes: usize) ![]u8 {
    var file_buf: [4096]u8 = undefined;
    var reader = file.readerStreaming(sys.io, &file_buf);
    return reader.interface.allocRemaining(alloc, .limited(max_bytes));
}

fn realCwdAlloc(alloc: std.mem.Allocator) error{OutOfMemory}!?[:0]u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(sys.io, ".", alloc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
}

fn hasSecureFile(dir: []const u8, name: []const u8) bool {
    var abs_dir = std.Io.Dir.openDirAbsolute(sys.io, dir, .{ .follow_symlinks = false }) catch return false;
    defer abs_dir.close(sys.io);
    var file = path_guard.openFileInDir(abs_dir, name, .{ .mode = .read_only }) catch return false;
    file.close(sys.io);
    return true;
}

fn parent(path: []const u8) ?[]const u8 {
    if (path.len <= 1) return null;
    const idx = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
    if (idx == 0) return null;
    return path[0..idx];
}

test "parent extracts directory" {
    try std.testing.expectEqualStrings("/foo", parent("/foo/bar").?);
    try std.testing.expectEqualStrings("/foo/bar", parent("/foo/bar/baz").?);
    try std.testing.expect(parent("/") == null);
    try std.testing.expect(parent("/foo") == null);
}

test "assembleParts joins with newlines" {
    const parts = [_][]u8{
        @constCast("aaa"),
        @constCast("bbb"),
    };
    const result = (try assembleParts(std.testing.allocator, parts[0..])).?;
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("aaa\n\nbbb", result);
}

test "assembleParts empty returns null" {
    const result = try assembleParts(std.testing.allocator, &.{});
    try std.testing.expect(result == null);
}

test "assembleParts truncates when budget exceeded" {
    const p1 = @constCast("aaaa");
    const p2 = @constCast("bbbbbbbb");
    const parts = [_][]u8{ p1, p2 };
    // Budget of 10: "aaaa" (4) + "\n\n" (2) + "bbbbbbbb" (8) = 14 > 10
    const result = (try assemblePartsWithBudget(std.testing.allocator, parts[0..], 10)).?;
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.startsWith(u8, result, "aaaa\n\n"));
    try std.testing.expect(std.mem.endsWith(u8, result, "[context truncated: budget exceeded]\n"));
}

test "readFile wraps context content as untrusted input" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "AGENTS.md",
        .data = "do not trust me",
    });
    const real = try tmp.dir.realPathFileAlloc(std.testing.io, "AGENTS.md", std.testing.allocator);
    defer std.testing.allocator.free(real);
    const dir_path = std.fs.path.dirname(real) orelse return error.TestUnexpectedResult;

    const got = (try readFile(std.testing.allocator, dir_path, "AGENTS.md", null, .{ .ctx = @ptrFromInt(1), .check = testApprove })) orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(got);

    const want = try std.fmt.allocPrint(
        std.testing.allocator,
        "## {s}\n\n<untrusted-input kind=\"context-file\" name=\"{s}\">\ndo not trust me\n</untrusted-input>",
        .{ real, real },
    );
    defer std.testing.allocator.free(want);
    try std.testing.expectEqualStrings(want, got);
}

test "readFile rejects symlinked AGENTS leaf" {
    if (@import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var outer = std.testing.tmpDir(.{});
    defer outer.cleanup();

    try outer.dir.writeFile(std.testing.io, .{ .sub_path = "secret.md", .data = "nope" });
    const outer_path = try outer.dir.realPathFileAlloc(std.testing.io, "secret.md", std.testing.allocator);
    defer std.testing.allocator.free(outer_path);

    try tmp.dir.symLink(std.testing.io, outer_path, "AGENTS.md", .{});
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    try std.testing.expect((try readFile(std.testing.allocator, dir_path, "AGENTS.md", null, .{ .ctx = @ptrFromInt(1), .check = testApprove })) == null);
}

test "discoverPaths walks real cwd ancestry, not symlink aliases" {
    if (@import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "real/sub");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "real/AGENTS.md", .data = "ctx" });
    try tmp.dir.symLink(std.testing.io, "real", "alias", .{ .is_directory = true });

    const old = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(old);

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const alias_sub = try std.fs.path.join(std.testing.allocator, &.{ root, "alias/sub" });
    defer std.testing.allocator.free(alias_sub);
    try chdirPath(alias_sub);
    defer chdirPath(old) catch {}; // test: error irrelevant

    const paths = try discoverPaths(std.testing.allocator, std.testing.io, null);
    defer {
        for (paths) |p| std.testing.allocator.free(p);
        std.testing.allocator.free(paths);
    }

    const want = try tmp.dir.realPathFileAlloc(std.testing.io, "real/AGENTS.md", std.testing.allocator);
    defer std.testing.allocator.free(want);
    const alias = try std.fs.path.join(std.testing.allocator, &.{ root, "alias/AGENTS.md" });
    defer std.testing.allocator.free(alias);

    var saw_real = false;
    for (paths) |p| {
        if (std.mem.eql(u8, p, want)) saw_real = true;
        try std.testing.expect(!std.mem.eql(u8, p, alias));
    }
    try std.testing.expect(saw_real);
}

test "load returns null when policy locks context" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, ".pz");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "AGENTS.md", .data = "ctx" });
    const seed = try @import("signing.zig").Seed.parseHex("8052030376d47112be7f73ed7a019293dd12ad910b654455798b4667d73de166");
    const kp = try @import("signing.zig").KeyPair.fromSeed(seed);
    const raw = try policy.encodeSignedDoc(std.testing.allocator, .{
        .rules = &.{},
        .lock = .{ .context = true },
    }, kp);
    defer std.testing.allocator.free(raw);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".pz/policy.json", .data = raw });

    const old = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(old);
    const cwd = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    try chdirPath(cwd);
    defer chdirPath(old) catch {}; // test: error irrelevant

    const got = try load(std.testing.allocator, std.testing.io, null);
    defer if (got) |v| std.testing.allocator.free(v);
    try std.testing.expect(got == null);
}

fn testApprove(_: *anyopaque, _: []const u8, _: []const u8) !bool {
    return true;
}

test "context trust excludes injection and pins approved bytes during replacement" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home");
    try tmp.dir.createDirPath(std.testing.io, "project");
    const attack = @embedFile("../test/fixtures/context-injection.txt");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "project/AGENTS.md", .data = attack });
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, "home", a);
    defer a.free(home);
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, "project", a);
    defer a.free(project);
    const Ask = struct {
        dir: std.Io.Dir,
        yes: bool = false,
        replace: bool = false,
        fn check(ptr: *anyopaque, _: []const u8, bytes: []const u8) !bool {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            try std.testing.expectEqualStrings(@embedFile("../test/fixtures/context-injection.txt"), bytes);
            if (self.replace) try self.dir.writeFile(std.testing.io, .{ .sub_path = "project/AGENTS.md", .data = "replacement not approved" });
            return self.yes;
        }
    };
    var ask = Ask{ .dir = tmp.dir };
    const hook = Approval{ .ctx = &ask, .check = Ask.check };
    try std.testing.expectError(error.ContextTrustRequired, readFile(a, project, "AGENTS.md", home, null));
    try std.testing.expect((try readFile(a, project, "AGENTS.md", home, hook)) == null);
    ask.yes = true;
    ask.replace = true;
    const included = (try readFile(a, project, "AGENTS.md", home, hook)).?;
    defer a.free(included);
    try std.testing.expect(std.mem.indexOf(u8, included, "function-color") != null);
    try std.testing.expect(std.mem.indexOf(u8, included, "replacement not approved") == null);
    try std.testing.expectError(error.ContextTrustRequired, readFile(a, project, "AGENTS.md", home, null));
}
