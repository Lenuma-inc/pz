//! Grep tool: regular expression search across files with path guarding.
const sys = @import("pz_io");
const std = @import("std");
const path_guard = @import("path_guard.zig");
const tools = @import("../tools.zig");
const shared = @import("shared.zig");
const noop = @import("../../test/noop_sink.zig");
const Acc = shared.Acc;

const Dir = std.Io.Dir;

pub const Err = error{
    KindMismatch,
    InvalidArgs,
    NotFound,
    Denied,
    TooLarge,
    Io,
    OutOfMemory,
};

pub const Opts = struct {
    alloc: std.mem.Allocator,
    max_bytes: usize,
    now_ms: i64 = 0,
    pre_open: ?*PreOpen = null,
};

pub const PreOpen = struct {
    vt: *const Vt,

    pub const Vt = struct {
        run: *const fn (self: *PreOpen, dir: Dir, rel_path: []const u8) anyerror!void,
    };

    pub fn call(self: *PreOpen, dir: Dir, rel_path: []const u8) !void {
        return self.vt.run(self, dir, rel_path);
    }

    pub fn Bind(comptime T: type, comptime run_fn: fn (*T, Dir, []const u8) anyerror!void) type {
        return struct {
            pub const vt = Vt{
                .run = runFn,
            };
            fn runFn(po: *PreOpen, dir: Dir, rel_path: []const u8) anyerror!void {
                const self_ptr: *T = @fieldParentPtr("pre_open", po);
                return run_fn(self_ptr, dir, rel_path);
            }
        };
    }
};

pub const Handler = struct {
    alloc: std.mem.Allocator,
    max_bytes: usize,
    now_ms: i64,
    pre_open: ?*PreOpen,

    pub fn init(opts: Opts) Handler {
        return .{
            .alloc = opts.alloc,
            .max_bytes = opts.max_bytes,
            .now_ms = opts.now_ms,
            .pre_open = opts.pre_open,
        };
    }

    pub fn run(self: Handler, call: tools.Call, _: *tools.Sink) Err!tools.Result {
        if (call.kind != .grep) return error.KindMismatch;
        if (std.meta.activeTag(call.args) != .grep) return error.KindMismatch;

        const args = call.args.grep;
        if (args.path.len == 0) return error.InvalidArgs;
        if (args.pattern.len == 0) return error.InvalidArgs;
        if (args.max_results == 0) return error.InvalidArgs;

        var acc = Acc.init(self.alloc, self.max_bytes);
        defer acc.deinit();

        var hit_ct: u32 = 0;
        var path = std.ArrayList(u8).empty;
        defer path.deinit(self.alloc);
        if (path_guard.openDir(args.path, .{ .iterate = true })) |opened| {
            var root = opened;
            defer root.close(sys.io);
            const found = std.process.run(self.alloc, sys.io, .{
                .argv = &.{ "fd", "--type", "f", "--print0", "--strip-cwd-prefix", if (std.mem.indexOfScalar(u8, args.glob, '/') != null) "--full-path" else "--case-sensitive", "--glob", args.glob },
                .expand_arg0 = .expand,
                .cwd = .{ .dir = root },
                .stdout_limit = .limited(8 * 1024 * 1024),
                .stderr_limit = .limited(4096),
            }) catch |err| return shared.mapFsErr(err);
            defer self.alloc.free(found.stdout);
            defer self.alloc.free(found.stderr);
            switch (found.term) {
                .exited => |code| if (code != 0) return error.InvalidArgs,
                else => return error.Io,
            }
            var selected: std.StringHashMapUnmanaged(void) = .empty;
            defer selected.deinit(self.alloc);
            var names = std.mem.splitScalar(u8, found.stdout, 0);
            while (names.next()) |name| {
                if (name.len == 0) continue;
                try selected.put(self.alloc, name, {});
                var end: usize = 0;
                while (std.mem.indexOfScalarPos(u8, name, end, '/')) |slash| {
                    try selected.put(self.alloc, name[0..slash], {});
                    end = slash + 1;
                }
            }
            try grepDir(self, root, &path, args, &hit_ct, &acc, &selected);
        } else |err| switch (err) {
            error.NotDir => {
                var parent = path_guard.openDir(std.fs.path.dirname(args.path) orelse ".", .{}) catch |open_err|
                    return shared.mapFsErr(open_err);
                defer parent.close(sys.io);
                try grepFile(self, parent, std.fs.path.basename(args.path), args.path, args, &hit_ct, &acc);
            },
            else => return shared.mapFsErr(err),
        }

        const data = acc.takeOwned() catch return error.OutOfMemory;
        errdefer self.alloc.free(data);

        return shared.buildResult(self.alloc, call.id, self.now_ms, data, self.max_bytes, acc.full_bytes) catch return error.OutOfMemory;
    }

    pub fn deinitResult(self: Handler, res: tools.Result) void {
        shared.deinitResult(self.alloc, res);
    }
};

fn grepDir(
    self: Handler,
    dir: Dir,
    path: *std.ArrayList(u8),
    args: tools.Call.GrepArgs,
    hit_ct: *u32,
    acc: *Acc,
    selected: *const std.StringHashMapUnmanaged(void),
) Err!void {
    const Child = struct { name: []u8, dir: Dir };
    var children: std.ArrayList(Child) = .empty;
    defer {
        for (children.items) |*child| {
            child.dir.close(sys.io);
            self.alloc.free(child.name);
        }
        children.deinit(self.alloc);
    }
    var it = dir.iterate();
    while (it.next(sys.io) catch |err| return shared.mapFsErr(err)) |ent| {
        if (hit_ct.* >= args.max_results) break;
        const base_len = path.items.len;
        if (base_len != 0) try path.append(self.alloc, '/');
        defer path.shrinkRetainingCapacity(base_len);
        try path.appendSlice(self.alloc, ent.name);
        if (!selected.contains(path.items)) continue;
        switch (ent.kind) {
            .directory => {
                const name = try self.alloc.dupe(u8, ent.name);
                errdefer self.alloc.free(name);
                var child = dir.openDir(sys.io, ent.name, .{ .iterate = true, .follow_symlinks = false }) catch |err| return shared.mapFsErr(err);
                errdefer child.close(sys.io);
                try children.append(self.alloc, .{ .name = name, .dir = child });
            },
            .file => try grepFile(self, dir, ent.name, path.items, args, hit_ct, acc),
            else => {},
        }
    }
    // Keep sibling directory handles stable when a search hook renames ancestors.
    for (children.items) |child| {
        if (hit_ct.* >= args.max_results) break;
        const base_len = path.items.len;
        if (base_len != 0) try path.append(self.alloc, '/');
        defer path.shrinkRetainingCapacity(base_len);
        try path.appendSlice(self.alloc, child.name);
        try grepDir(self, child.dir, path, args, hit_ct, acc, selected);
    }
}

fn grepFile(
    self: Handler,
    dir: Dir,
    name: []const u8,
    rel_path: []const u8,
    args: tools.Call.GrepArgs,
    hit_ct: *u32,
    acc: *Acc,
) Err!void {
    if (self.pre_open) |hook| {
        hook.call(dir, rel_path) catch |hook_err| return shared.mapFsErr(hook_err);
    }

    var file = path_guard.openFileInDir(dir, name, .{ .mode = .read_only }) catch |open_err| {
        return shared.mapFsErr(open_err);
    };
    defer file.close(sys.io);

    const count = std.fmt.allocPrint(self.alloc, "{d}", .{args.max_results - hit_ct.*}) catch return error.OutOfMemory;
    defer self.alloc.free(count);
    const result = shared.runFile(self.alloc, file, &.{
        "rg",                                                          "--no-config", "--line-number", "--no-heading", "--color", "never", "--max-columns", "240", "--max-columns-preview", "--max-count", count,
        if (args.ignore_case) "--ignore-case" else "--case-sensitive", "--regexp",    args.pattern,
    }, self.max_bytes + 4096) catch |err| return shared.mapFsErr(err);
    defer self.alloc.free(result.stdout);
    defer self.alloc.free(result.stderr);
    switch (result.term) {
        .exited => |code| switch (code) {
            0 => {},
            1 => return,
            2 => return error.InvalidArgs,
            else => return error.Io,
        },
        else => return error.Io,
    }
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try acc.append(rel_path);
        try acc.append(":");
        try acc.append(line);
        try acc.append("\n");
        hit_ct.* += 1;
    }
}

test "grep handler finds matching lines with file and line numbers" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap.default;
    const Snap = struct {
        has_a: bool,
        has_b: bool,
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd = try path_guard.CwdGuard.enter(tmp.dir);
    defer cwd.deinit();

    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/a.txt", .data = "alpha\nbeta\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/b.txt", .data = "Beta\n" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, "src", std.testing.allocator);
    defer std.testing.allocator.free(root);

    const sink = noop.sink();

    const handler = Handler.init(.{
        .alloc = std.testing.allocator,
        .max_bytes = 1024,
        .now_ms = 9,
    });
    const call: tools.Call = .{
        .id = "g1",
        .kind = .grep,
        .args = .{
            .grep = .{
                .path = root,
                .pattern = "beta",
                .ignore_case = true,
            },
        },
        .src = .model,
        .at_ms = 0,
    };

    const res = try handler.run(call, sink);
    defer handler.deinitResult(res);

    try oh.snap(@src(),
        \\core.tools.grep.test.grep handler finds matching lines with file and line numbers.Snap
        \\  .has_a: bool = true
        \\  .has_b: bool = true
    ).expectEqual(Snap{
        .has_a = std.mem.indexOf(u8, res.out[0].chunk, "a.txt:2:beta\n") != null,
        .has_b = std.mem.indexOf(u8, res.out[0].chunk, "b.txt:1:Beta\n") != null,
    });
}

test "grep handler validates args and missing roots" {
    const sink = noop.sink();

    const handler = Handler.init(.{
        .alloc = std.testing.allocator,
        .max_bytes = 64,
    });

    const bad: tools.Call = .{
        .id = "g2",
        .kind = .grep,
        .args = .{
            .grep = .{ .path = ".", .pattern = "", .max_results = 1 },
        },
        .src = .model,
        .at_ms = 0,
    };
    try std.testing.expectError(error.InvalidArgs, handler.run(bad, sink));

    const missing: tools.Call = .{
        .id = "g3",
        .kind = .grep,
        .args = .{
            .grep = .{ .path = "no-such-dir-9477", .pattern = "x" },
        },
        .src = .model,
        .at_ms = 0,
    };
    try std.testing.expectError(error.NotFound, handler.run(missing, sink));
}

test "grep handler denies hardlinked leaf" {
    if (@import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd = try path_guard.CwdGuard.enter(tmp.dir);
    defer cwd.deinit();

    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/base.txt", .data = "secret\n" });
    try tmp.dir.hardLink("src/base.txt", tmp.dir, "src/alias.txt", std.testing.io, .{});

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, "src", std.testing.allocator);
    defer std.testing.allocator.free(root);

    const sink = noop.sink();

    const handler = Handler.init(.{
        .alloc = std.testing.allocator,
        .max_bytes = 128,
    });
    try std.testing.expectError(error.Denied, handler.run(.{
        .id = "g-link",
        .kind = .grep,
        .args = .{
            .grep = .{
                .path = root,
                .pattern = "secret",
            },
        },
        .src = .model,
        .at_ms = 0,
    }, sink));
}

test "grep handler keeps trusted dir after ancestor swap" {
    if (@import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) return;

    const HookCtx = struct {
        pre_open: PreOpen = .{ .vt = &Bind.vt },
        root: std.Io.Dir,
        done: bool = false,

        fn run(self: *@This(), _: std.Io.Dir, rel_path: []const u8) !void {
            if (self.done) return;
            if (!std.mem.eql(u8, rel_path, "sub/victim.txt")) return;
            self.done = true;
            try self.root.rename("sub", self.root, "gone", std.testing.io);
            try self.root.rename("swap", self.root, "sub", std.testing.io);
        }
        const Bind = PreOpen.Bind(@This(), run);
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd = try path_guard.CwdGuard.enter(tmp.dir);
    defer cwd.deinit();

    try tmp.dir.createDirPath(std.testing.io, "src/sub");
    try tmp.dir.createDirPath(std.testing.io, "src/swap");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/sub/victim.txt", .data = "secret\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/swap/victim.txt", .data = "hacked\n" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, "src", std.testing.allocator);
    defer std.testing.allocator.free(root);

    const sink = noop.sink();

    var ctx = HookCtx{ .root = try tmp.dir.openDir(std.testing.io, "src", .{ .access_sub_paths = true }) };
    defer ctx.root.close(std.testing.io);

    const handler = Handler.init(.{
        .alloc = std.testing.allocator,
        .max_bytes = 256,
        .pre_open = &ctx.pre_open,
    });
    const res = try handler.run(.{
        .id = "g-race",
        .kind = .grep,
        .args = .{
            .grep = .{
                .path = root,
                .pattern = "secret",
            },
        },
        .src = .model,
        .at_ms = 0,
    }, sink);
    defer handler.deinitResult(res);

    try std.testing.expectEqualStrings("sub/victim.txt:1:secret\n", res.out[0].chunk);
}
