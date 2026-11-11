//! JSONL session event writer with configurable flush policy.
const sys = @import("pz_io");
const std = @import("std");
const posix = std.posix;
const schema = @import("schema.zig");
const sid_path = @import("path.zig");
const fs_secure = @import("../fs_secure.zig");
const OhSnap = @import("ohsnap");

pub const Event = schema.Event;
const Dir = std.Io.Dir;

fn seekEnd(file: std.Io.File) !void {
    const rc = std.c.lseek(file.handle, 0, std.c.SEEK.END);
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => |err| return std.posix.unexpectedErrno(err),
    }
    if (rc == 0) return;

    // Never append an event to an incomplete record left by a failed write.
    // Preserve the torn tail for diagnosis rather than turning it into malformed JSON.
    const tail = std.c.lseek(file.handle, -1, std.c.SEEK.END);
    switch (std.posix.errno(tail)) {
        .SUCCESS => {},
        else => |err| return std.posix.unexpectedErrno(err),
    }
    var byte: [1]u8 = undefined;
    const n = try file.readStreaming(sys.io, &.{byte[0..]});
    if (n != 1 or byte[0] != '\n') return error.TornReplayLine;
}

/// When to fsync: after every write or every N writes.
pub const FlushPolicy = union(enum) {
    always: void,
    every_n: u32,
};

pub const Opts = struct {
    flush: FlushPolicy = .{ .always = {} },
};

pub const Writer = struct {
    alloc: std.mem.Allocator,
    dir: Dir,
    flush: FlushPolicy,
    pending: u32 = 0,

    pub fn init(alloc: std.mem.Allocator, dir: Dir, opts: Opts) !Writer {
        switch (opts.flush) {
            .always => {},
            .every_n => |n| {
                if (n == 0) return error.InvalidFlushEvery;
            },
        }

        return .{
            .alloc = alloc,
            .dir = dir,
            .flush = opts.flush,
        };
    }

    pub fn append(self: *Writer, sid: []const u8, ev: Event) !void {
        const path = try sid_path.sidJsonlAlloc(self.alloc, sid);
        defer self.alloc.free(path);

        const raw = try schema.encodeAlloc(self.alloc, ev);
        defer self.alloc.free(raw);

        // Confined create: O_NOFOLLOW + hardlink check for .pz state.
        var file = try fs_secure.createConfined(self.dir, path, .{
            .read = true,
            .truncate = false,
        });
        defer file.close(sys.io);
        try seekEnd(file);
        const nl = "\n";
        try file.writeStreamingAll(sys.io, raw);
        try file.writeStreamingAll(sys.io, nl);

        switch (self.flush) {
            .always => {
                try file.sync(sys.io);
            },
            .every_n => |n| {
                self.pending += 1;
                if (self.pending >= n) {
                    try file.sync(sys.io);
                    self.pending = 0;
                }
            },
        }
    }
};

test "jsonl append preserves event order" {
    const oh = OhSnap.default;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var writer = try Writer.init(std.testing.allocator, tmp.dir, .{
        .flush = .{ .always = {} },
    });

    try writer.append("s1", .{
        .at_ms = 1,
        .data = .{ .prompt = .{ .text = "alpha" } },
    });
    try writer.append("s1", .{
        .at_ms = 2,
        .data = .{ .text = .{ .text = "beta" } },
    });
    try writer.append("s1", .{
        .at_ms = 3,
        .data = .{ .err = .{ .text = "gamma" } },
    });

    const raw = try tmp.dir.readFileAlloc(std.testing.io, "s1.jsonl", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(raw);

    var rows = std.ArrayListUnmanaged(schema.Event).empty;
    defer {
        for (rows.items) |row| row.free(std.testing.allocator);
        rows.deinit(std.testing.allocator);
    }

    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        var parsed = try schema.decodeSlice(std.testing.allocator, line);
        defer parsed.deinit();
        try rows.append(std.testing.allocator, try parsed.value.dupe(std.testing.allocator));
    }

    try oh.snap(@src(),
        \\[]core.session.schema.Event
        \\  [0]: core.session.schema.Event
        \\    .version: u16 = 1
        \\    .at_ms: i64 = 1
        \\    .data: core.session.schema.Event.Data
        \\      .prompt: core.session.schema.Event.Prompt
        \\        .text: []const u8
        \\          "alpha"
        \\        .attachments: []const core.session.schema.Event.Attachment
        \\          (empty)
        \\  [1]: core.session.schema.Event
        \\    .version: u16 = 1
        \\    .at_ms: i64 = 2
        \\    .data: core.session.schema.Event.Data
        \\      .text: core.session.schema.Event.Text
        \\        .text: []const u8
        \\          "beta"
        \\  [2]: core.session.schema.Event
        \\    .version: u16 = 1
        \\    .at_ms: i64 = 3
        \\    .data: core.session.schema.Event.Data
        \\      .err: core.session.schema.Event.Text
        \\        .text: []const u8
        \\          "gamma"
    ).expectEqual(rows.items);
    if (@import("builtin").os.tag != .windows) {
        const st = try tmp.dir.statFile(std.testing.io, "s1.jsonl", .{});
        try std.testing.expectEqual(fs_secure.file_mode.toMode() & 0o777, st.permissions.toMode() & 0o777);
    }
}

test "writer rejects invalid flush policy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expectError(
        error.InvalidFlushEvery,
        Writer.init(std.testing.allocator, tmp.dir, .{
            .flush = .{ .every_n = 0 },
        }),
    );
}

test "writer rejects invalid session id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var writer = try Writer.init(std.testing.allocator, tmp.dir, .{
        .flush = .{ .every_n = 2 },
    });

    try std.testing.expectError(error.InvalidSessionId, writer.append("", .{}));
    try std.testing.expectError(error.InvalidSessionId, writer.append("a/b", .{}));
}

test "writer preserves torn tail instead of appending to it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var writer = try Writer.init(std.testing.allocator, tmp.dir, .{});
    try writer.append("torn", .{ .data = .{ .text = .{ .text = "complete" } } });
    const before = try tmp.dir.readFileAlloc(std.testing.io, "torn.jsonl", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(before);
    const torn = try std.mem.concat(std.testing.allocator, u8, &.{ before, "{\"version\":1" });
    defer std.testing.allocator.free(torn);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "torn.jsonl", .data = torn });
    try std.testing.expectError(error.TornReplayLine, writer.append("torn", .{ .data = .{ .err = .{ .text = "replay failed" } } }));
    const after = try tmp.dir.readFileAlloc(std.testing.io, "torn.jsonl", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(torn, after);
}
