//! Bounded before/after snapshots for shell edits, using fd's ignore rules.
const std = @import("std");
const sys = @import("pz_io");
const guard = @import("path_guard.zig");
const shared = @import("shared.zig");

const file_limit = 1024 * 1024;
const total_limit = 16 * file_limit;

pub const Snapshot = struct {
    files: std.StringArrayHashMapUnmanaged(?[]u8) = .empty,
    skipped: usize = 0,

    pub fn deinit(self: *Snapshot, alloc: std.mem.Allocator) void {
        for (self.files.keys(), self.files.values()) |path, text| {
            alloc.free(path);
            if (text) |bytes| alloc.free(bytes);
        }
        self.files.deinit(alloc);
    }

    pub fn capture(alloc: std.mem.Allocator, root: []const u8) !Snapshot {
        var dir = try guard.openDir(root, .{});
        defer dir.close(sys.io);
        const paths = try std.process.run(alloc, sys.io, .{
            .argv = &.{ "fd", "--type", "f", "--print0", "--color", "never", "--exclude", "*.stdout", ".", "." },
            .expand_arg0 = .expand,
            .cwd = .{ .dir = dir },
            .stdout_limit = .limited(file_limit),
            .stderr_limit = .limited(4096),
        });
        defer alloc.free(paths.stdout);
        defer alloc.free(paths.stderr);
        switch (paths.term) {
            .exited => |code| if (code != 0) return error.ChangeScanFailed,
            else => return error.ChangeScanFailed,
        }
        var self: Snapshot = .{};
        errdefer self.deinit(alloc);
        var total: usize = 0;
        var it = std.mem.splitScalar(u8, paths.stdout, 0);
        while (it.next()) |path| {
            if (path.len == 0) continue;
            const key = try alloc.dupe(u8, std.mem.trimStart(u8, path, "./"));
            self.files.put(alloc, key, null) catch |err| {
                alloc.free(key);
                return err;
            };
            if (total >= total_limit) {
                self.skipped += 1;
                continue;
            }
            const full = try std.fs.path.join(alloc, &.{ root, path });
            defer alloc.free(full);
            const text = read(alloc, full, @min(file_limit, total_limit - total)) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    self.skipped += 1;
                    continue;
                },
            };
            errdefer alloc.free(text);
            total += text.len;
            if (std.mem.indexOfScalar(u8, text, 0) != null) {
                alloc.free(text);
                self.skipped += 1;
                continue;
            }
            self.files.getPtr(key).?.* = text;
        }
        self.files.sort(struct {
            keys: []const []const u8,
            pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                return std.mem.lessThan(u8, ctx.keys[a], ctx.keys[b]);
            }
        }{ .keys = self.files.keys() });
        return self;
    }
};

fn read(alloc: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    const file = try guard.openFile(path, .{ .mode = .read_only });
    defer file.close(sys.io);
    var buf: [4096]u8 = undefined;
    var reader = file.readerStreaming(sys.io, &buf);
    return reader.interface.allocRemaining(alloc, .limited(limit));
}

pub fn diff(alloc: std.mem.Allocator, before: Snapshot, after: Snapshot, limit: usize) ![]u8 {
    var out = shared.Acc.init(alloc, limit);
    defer out.deinit();
    for (before.files.keys(), before.files.values()) |path, old_opt| {
        const old = old_opt orelse continue;
        if (after.files.getPtr(path)) |new_opt| {
            const new = new_opt.* orelse continue;
            if (!std.mem.eql(u8, old, new)) try appendDiff(alloc, &out, path, old, new);
        } else {
            try appendDiff(alloc, &out, path, old, "");
        }
    }
    for (after.files.keys(), after.files.values()) |path, new_opt| {
        const new = new_opt orelse continue;
        if (!before.files.contains(path)) try appendDiff(alloc, &out, path, "", new);
    }
    const truncated = out.full_bytes > limit;
    if (truncated) try out.buf.appendSlice(alloc, "\n[diff truncated]\n");
    if (before.skipped != 0 or after.skipped != 0) {
        const note = try std.fmt.allocPrint(alloc, "\n[diff incomplete: skipped {d} files before, {d} after; unreadable, binary or snapshot limits]\n", .{ before.skipped, after.skipped });
        defer alloc.free(note);
        try out.buf.appendSlice(alloc, note);
    }
    if (out.buf.items.len != 0) try out.buf.appendSlice(alloc, "[diff scope: visible, non-ignored files in the command workspace; 1 MiB/file, 16 MiB total]\n");
    return out.takeOwned();
}

fn appendDiff(alloc: std.mem.Allocator, out: *shared.Acc, path: []const u8, old: []const u8, new: []const u8) !void {
    const header = try std.fmt.allocPrint(alloc, "diff --git a/{s} b/{s}\n", .{ path, path });
    defer alloc.free(header);
    try out.append(header);
    const body = try shared.formatDiffAlloc(alloc, path, old, old, new);
    defer alloc.free(body);
    try out.append(body);
}

test "shell changes show only this command's edits, additions and deletions" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "same.txt", .data = "pre-existing user edit\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "edit.txt", .data = "old\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "gone.txt", .data = "gone\n" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(root);
    var before = try Snapshot.capture(alloc, root);
    defer before.deinit(alloc);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "edit.txt", .data = "new\n" });
    try tmp.dir.deleteFile(std.testing.io, "gone.txt");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "added.txt", .data = "added\n" });
    var after = try Snapshot.capture(alloc, root);
    defer after.deinit(alloc);
    const text = try diff(alloc, before, after, 4096);
    defer alloc.free(text);
    try @import("../../test/helpers.zig").expectSnapText(
        @src(),
        "diff --git a/edit.txt b/edit.txt\n• Edited edit.txt (+1 -1)\n@@ -1,1 +1,1 @@\n-old\n+new\ndiff --git a/gone.txt b/gone.txt\n• Edited gone.txt (+0 -1)\n@@ -1,1 +1,0 @@\n-gone\ndiff --git a/added.txt b/added.txt\n• Edited added.txt (+1 -0)\n@@ -1,0 +1,1 @@\n+added\n[diff scope: visible, non-ignored files in the command workspace; 1 MiB/file, 16 MiB total]\n",
        text,
    );
}
