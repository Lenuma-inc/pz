//! File write tool with path guarding.
const sys = @import("pz_io");
const std = @import("std");
const path_guard = @import("path_guard.zig");
const tools = @import("../tools.zig");
const shared = @import("shared.zig");
const noop = @import("../../test/noop_sink.zig");

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
        if (call.kind != .write) return error.KindMismatch;
        if (std.meta.activeTag(call.args) != .write) return error.KindMismatch;

        const args = call.args.write;
        if (args.path.len == 0) return error.InvalidArgs;

        const old = if (args.append) null else try readExistingAlloc(self.alloc, args.path, self.max_bytes);
        defer if (old) |data| self.alloc.free(data);
        const diff = if (args.append)
            try shared.formatAppendDiffAlloc(self.alloc, args.path, args.text)
        else if (old) |data|
            try shared.formatDiffAlloc(self.alloc, args.path, data, data, args.text)
        else
            try std.fmt.allocPrint(self.alloc, "• Edited {s} (diff omitted: existing file exceeds {d} bytes)\n", .{ std.fs.path.basename(args.path), self.max_bytes });
        defer self.alloc.free(diff);
        const result = try shared.buildSlicedResult(self.alloc, call.id, self.now_ms, tools.truncate.apply(diff, self.max_bytes));
        errdefer shared.deinitResult(self.alloc, result);

        var file = path_guard.createFile(args.path, .{
            .truncate = !args.append,
        }) catch |open_err| {
            return shared.mapFsErr(open_err);
        };
        defer file.close(sys.io);

        if (args.append) {
            try seekEnd(file);
        }

        file.writeStreamingAll(sys.io, args.text) catch |write_err| {
            return shared.mapFsErr(write_err);
        };

        return result;
    }
};

fn readExistingAlloc(alloc: std.mem.Allocator, path: []const u8, max_bytes: usize) Err!?[]u8 {
    var file = path_guard.openFile(path, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => return try alloc.dupe(u8, ""),
        else => return shared.mapFsErr(err),
    };
    defer file.close(sys.io);
    var buf: [4096]u8 = undefined;
    var reader = file.readerStreaming(sys.io, &buf);
    return reader.interface.allocRemaining(alloc, .limited(max_bytes)) catch |err| switch (err) {
        error.StreamTooLong => null,
        error.OutOfMemory => error.OutOfMemory,
        else => shared.mapFsErr(err),
    };
}

fn seekEnd(file: std.Io.File) Err!void {
    const rc = std.c.lseek(file.handle, 0, std.c.SEEK.END);
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => |err| return shared.mapFsErr(std.posix.unexpectedErrno(err)),
    }
}

test "write handler overwrites file with deterministic timestamps" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap.default;
    const Snap = struct {
        res: tools.Result,
        file: []const u8,
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd = try path_guard.CwdGuard.enter(tmp.dir);
    defer cwd.deinit();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "out.txt", .data = "old" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "out.txt", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const sink = noop.sink();

    const handler = Handler.init(.{ .alloc = std.testing.allocator, .max_bytes = 1024, .now_ms = 77 });
    const call: tools.Call = .{
        .id = "w1",
        .kind = .write,
        .args = .{
            .write = .{
                .path = path,
                .text = "new",
                .append = false,
            },
        },
        .src = .system,
        .at_ms = 1,
    };

    const res = try handler.run(call, sink);
    defer shared.deinitResult(std.testing.allocator, res);

    const got = try tmp.dir.readFileAlloc(std.testing.io, "out.txt", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(got);
    const snap = Snap{
        .res = res,
        .file = got,
    };
    try oh.snap(@src(),
        \\core.tools.write.test.write handler overwrites file with deterministic timestamps.Snap
        \\  .res: core.tools.Result
        \\    .call_id: []const u8
        \\      "w1"
        \\    .started_at_ms: i64 = 77
        \\    .ended_at_ms: i64 = 77
        \\    .out: []const core.tools.Output
        \\      [0]: core.tools.Output
        \\        .call_id: []const u8
        \\          "w1"
        \\        .seq: u32 = 0
        \\        .at_ms: i64 = 77
        \\        .stream: core.tools.Output.Stream
        \\          .stdout
        \\        .chunk: []const u8
        \\          "• Edited out.txt (+1 -1)
        \\@@ -1,1 +1,1 @@
        \\-old
        \\+new
        \\"
        \\        .owned: bool = true
        \\        .truncated: bool = false
        \\    .out_owned: bool = true
        \\    .out_streamed: bool = false
        \\    .final: core.tools.Result.Final
        \\      .ok: core.tools.Result.Ok
        \\        .code: i32 = 0
        \\  .file: []const u8
        \\    "new"
    ).expectEqual(snap);
}

test "write handler appends when append is true" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd = try path_guard.CwdGuard.enter(tmp.dir);
    defer cwd.deinit();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "out.txt", .data = "a" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "out.txt", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const sink = noop.sink();

    const handler = Handler.init(.{ .alloc = std.testing.allocator, .max_bytes = 1024 });
    const call: tools.Call = .{
        .id = "w2",
        .kind = .write,
        .args = .{
            .write = .{
                .path = path,
                .text = "b",
                .append = true,
            },
        },
        .src = .system,
        .at_ms = 0,
    };

    const res = try handler.run(call, sink);
    defer shared.deinitResult(std.testing.allocator, res);
    try std.testing.expect(std.mem.indexOf(u8, res.out[0].chunk, "Edited out.txt (+1 -0)\n@@ append @@\n+b") != null);

    const got = try tmp.dir.readFileAlloc(std.testing.io, "out.txt", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("ab", got);
}

test "write handler returns invalid args for empty path" {
    const sink = noop.sink();

    const handler = Handler.init(.{ .alloc = std.testing.allocator, .max_bytes = 1024 });
    const call: tools.Call = .{
        .id = "w3",
        .kind = .write,
        .args = .{
            .write = .{
                .path = "",
                .text = "x",
            },
        },
        .src = .system,
        .at_ms = 0,
    };

    try std.testing.expectError(error.InvalidArgs, handler.run(call, sink));
}

test "write handler returns not found for missing parent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd = try path_guard.CwdGuard.enter(tmp.dir);
    defer cwd.deinit();

    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    const path = try std.fs.path.join(std.testing.allocator, &.{
        dir_path,
        "missing",
        "out.txt",
    });
    defer std.testing.allocator.free(path);

    const sink = noop.sink();

    const handler = Handler.init(.{ .alloc = std.testing.allocator, .max_bytes = 1024 });
    const call: tools.Call = .{
        .id = "w4",
        .kind = .write,
        .args = .{
            .write = .{
                .path = path,
                .text = "x",
            },
        },
        .src = .model,
        .at_ms = 0,
    };

    try std.testing.expectError(error.NotFound, handler.run(call, sink));
}

test "write handler returns kind mismatch for wrong call kind" {
    const sink = noop.sink();

    const handler = Handler.init(.{ .alloc = std.testing.allocator, .max_bytes = 1024 });
    const call: tools.Call = .{
        .id = "w5",
        .kind = .read,
        .args = .{
            .read = .{
                .path = "x",
            },
        },
        .src = .model,
        .at_ms = 0,
    };

    try std.testing.expectError(error.KindMismatch, handler.run(call, sink));
}

test "write handler denies replaced target before truncation" {
    if (@import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) return;

    const HookCtx = struct {
        race_hook: path_guard.RaceHook = .{ .vt = &Bind.vt },
        fn run(_: *@This(), dir: std.Io.Dir, path: []const u8) !void {
            try dir.rename(path, dir, "gone.txt", std.testing.io);
            try dir.rename("swap.txt", dir, path, std.testing.io);
        }
        const Bind = path_guard.RaceHook.Bind(@This(), run);
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd = try path_guard.CwdGuard.enter(tmp.dir);
    defer cwd.deinit();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "victim.txt", .data = "keep\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "swap.txt", .data = "swap\n" });

    const sink = noop.sink();

    var hook_ctx = HookCtx{};
    var hook = path_guard.installRaceHook(&hook_ctx.race_hook);
    defer hook.deinit();

    const handler = Handler.init(.{ .alloc = std.testing.allocator, .max_bytes = 1024 });
    try std.testing.expectError(error.Denied, handler.run(.{
        .id = "w-race",
        .kind = .write,
        .args = .{
            .write = .{
                .path = "victim.txt",
                .text = "overwrite\n",
            },
        },
        .src = .model,
        .at_ms = 0,
    }, sink));

    const kept = try tmp.dir.readFileAlloc(std.testing.io, "victim.txt", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(kept);
    try std.testing.expectEqualStrings("swap\n", kept);
}
