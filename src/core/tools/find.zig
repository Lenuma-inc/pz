//! File find tool: glob-based search with path guarding.
const sys = @import("pz_io");
const std = @import("std");
const path_guard = @import("path_guard.zig");
const tools = @import("../tools.zig");
const shared = @import("shared.zig");
const tool_snap = @import("../../test/tool_snap.zig");
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
};

pub const Handler = struct {
    alloc: std.mem.Allocator,
    max_bytes: usize,
    now_ms: i64,

    pub fn init(opts: Opts) Handler {
        return .{
            .alloc = opts.alloc,
            .max_bytes = opts.max_bytes,
            .now_ms = opts.now_ms,
        };
    }

    pub fn run(self: Handler, call: tools.Call, _: *tools.Sink) Err!tools.Result {
        if (call.kind != .find) return error.KindMismatch;
        if (std.meta.activeTag(call.args) != .find) return error.KindMismatch;

        const args = call.args.find;
        if (args.path.len == 0) return error.InvalidArgs;
        if (args.name.len == 0 and args.pattern == null) return error.InvalidArgs;
        if (args.name.len != 0 and args.pattern != null) return error.InvalidArgs;
        if (args.max_results == 0) return error.InvalidArgs;

        var root = path_guard.openDir(args.path, .{ .iterate = true }) catch |open_err| {
            return shared.mapFsErr(open_err);
        };
        defer root.close(sys.io);

        var matches = std.ArrayList([]u8).empty;
        defer {
            for (matches.items) |m| self.alloc.free(m);
            matches.deinit(self.alloc);
        }

        const result = std.process.run(self.alloc, sys.io, .{
            .argv = &.{ "fd", "--color", "never", "--print0", "--strip-cwd-prefix", if (std.mem.indexOfScalar(u8, args.pattern orelse "", '/') != null) "--full-path" else "--case-sensitive", if (args.pattern != null) "--glob" else "--fixed-strings", "--", args.pattern orelse args.name },
            .expand_arg0 = .expand,
            .cwd = .{ .dir = root },
            .stdout_limit = .limited(8 * 1024 * 1024),
            .stderr_limit = .limited(4096),
        }) catch |err| return shared.mapFsErr(err);
        defer self.alloc.free(result.stdout);
        defer self.alloc.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) return error.InvalidArgs,
            else => return error.Io,
        }
        var paths = std.mem.splitScalar(u8, result.stdout, 0);
        while (paths.next()) |path| {
            if (path.len == 0) continue;
            const clean = std.mem.trimEnd(u8, path, "/");
            const dup = try self.alloc.dupe(u8, clean);
            errdefer self.alloc.free(dup);
            try matches.append(self.alloc, dup);
        }

        std.sort.pdq([]u8, matches.items, {}, lessPath);

        var acc = Acc.init(self.alloc, self.max_bytes);
        defer acc.deinit();

        const emit_len = @min(matches.items.len, @as(usize, args.max_results));
        for (matches.items[0..emit_len]) |match_path| {
            try acc.append(match_path);
            try acc.append("\n");
        }

        const data = acc.takeOwned() catch return error.OutOfMemory;
        errdefer self.alloc.free(data);

        return shared.buildResult(self.alloc, call.id, self.now_ms, data, self.max_bytes, acc.full_bytes) catch return error.OutOfMemory;
    }

    pub fn deinitResult(self: Handler, res: tools.Result) void {
        shared.deinitResult(self.alloc, res);
    }
};

fn lessPath(_: void, a: []u8, b: []u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

test "find handler lists matching paths in sorted order" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap.default;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd = try path_guard.CwdGuard.enter(tmp.dir);
    defer cwd.deinit();

    try tmp.dir.createDirPath(std.testing.io, "src/lib");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/a.zig", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/lib/b.zig", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/lib/c.txt", .data = "" });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, "src", std.testing.allocator);
    defer std.testing.allocator.free(root);

    const sink = noop.sink();

    const handler = Handler.init(.{
        .alloc = std.testing.allocator,
        .max_bytes = 1024,
        .now_ms = 7,
    });
    const call: tools.Call = .{
        .id = "f1",
        .kind = .find,
        .args = .{
            .find = .{
                .path = root,
                .name = ".zig",
            },
        },
        .src = .model,
        .at_ms = 0,
    };

    const res = try handler.run(call, sink);
    defer handler.deinitResult(res);
    const snap = try tool_snap.resultAlloc(std.testing.allocator, res);
    defer std.testing.allocator.free(snap);
    try oh.snap(@src(),
        \\[]u8
        \\  "call=f1
        \\start=7
        \\end=7
        \\out=1
        \\0=f1|7|stdout|false|a.zig
        \\lib/b.zig
        \\
        \\final=ok|0
        \\"
    ).expectEqual(snap);
}

test "find handler validates args and handles missing roots" {
    const sink = noop.sink();

    const handler = Handler.init(.{
        .alloc = std.testing.allocator,
        .max_bytes = 64,
    });

    const bad: tools.Call = .{
        .id = "f2",
        .kind = .find,
        .args = .{
            .find = .{ .path = ".", .name = "", .max_results = 1 },
        },
        .src = .model,
        .at_ms = 0,
    };
    try std.testing.expectError(error.InvalidArgs, handler.run(bad, sink));

    const missing: tools.Call = .{
        .id = "f3",
        .kind = .find,
        .args = .{
            .find = .{ .path = "no-such-dir-8572", .name = "x" },
        },
        .src = .model,
        .at_ms = 0,
    };
    try std.testing.expectError(error.NotFound, handler.run(missing, sink));
}

test "find handler truncates on high hit count instead of erroring" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd = try path_guard.CwdGuard.enter(tmp.dir);
    defer cwd.deinit();

    // Create more files than max_results * 8
    try tmp.dir.createDirPath(std.testing.io, "d");
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        var name: [12]u8 = undefined;
        const n = try std.fmt.bufPrint(&name, "d/f{d}.txt", .{i});
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = n, .data = "" });
    }

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, "d", std.testing.allocator);
    defer std.testing.allocator.free(root);

    const sink = noop.sink();

    const handler = Handler.init(.{
        .alloc = std.testing.allocator,
        .max_bytes = 4096,
        .now_ms = 0,
    });
    const call: tools.Call = .{
        .id = "f4",
        .kind = .find,
        .args = .{
            .find = .{
                .path = root,
                .name = ".txt",
                .max_results = 2, // collect_limit = 2 * 8 = 16 < 20 files
            },
        },
        .src = .model,
        .at_ms = 0,
    };

    // Should succeed (truncated) instead of erroring
    const res = try handler.run(call, sink);
    defer handler.deinitResult(res);

    // Should have 1 data chunk with at most max_results lines
    try std.testing.expect(res.out.len >= 1);
    const chunk = res.out[0].chunk;
    var lines: usize = 0;
    for (chunk) |c| {
        if (c == '\n') lines += 1;
    }
    try std.testing.expect(lines <= 2);
}
