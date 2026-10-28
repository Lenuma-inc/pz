//! Apply a unified diff to one explicitly authorized file.
const std = @import("std");
const sys = @import("pz_io");
const tools = @import("../tools.zig");
const path_guard = @import("path_guard.zig");
const edit = @import("edit.zig");
const write = @import("write.zig");

pub fn run(alloc: std.mem.Allocator, max_bytes: usize, call: tools.Call, sink: *tools.Sink) !tools.Result {
    const args = call.args.patch;
    const old = if (path_guard.openFile(args.path, .{ .mode = .read_only })) |opened| blk: {
        var file = opened;
        defer file.close(sys.io);
        var buf: [4096]u8 = undefined;
        var reader = file.readerStreaming(sys.io, &buf);
        break :blk try reader.interface.allocRemaining(alloc, .limited(max_bytes));
    } else |err| switch (err) {
        error.FileNotFound => try alloc.dupe(u8, ""),
        else => return err,
    };
    defer alloc.free(old);
    const updated = try applyAlloc(alloc, old, args.patch, max_bytes);
    defer alloc.free(updated);
    if (old.len == 0) {
        return write.Handler.init(.{ .alloc = alloc, .max_bytes = max_bytes, .now_ms = call.at_ms }).run(.{
            .id = call.id,
            .kind = .write,
            .args = .{ .write = .{ .path = args.path, .text = updated } },
            .src = call.src,
            .at_ms = call.at_ms,
        }, sink);
    }
    return edit.Handler.init(.{ .alloc = alloc, .max_bytes = max_bytes, .now_ms = call.at_ms }).run(.{
        .id = call.id,
        .kind = .edit,
        .args = .{ .edit = .{ .path = args.path, .old = old, .new = updated } },
        .src = call.src,
        .at_ms = call.at_ms,
    }, sink);
}

const Range = struct { start: usize, count: usize };
fn range(raw: []const u8, sign: u8) !Range {
    if (raw.len < 2 or raw[0] != sign) return error.InvalidPatch;
    var parts = std.mem.splitScalar(u8, raw[1..], ',');
    const start = try std.fmt.parseInt(usize, parts.next().?, 10);
    const count = if (parts.next()) |n| try std.fmt.parseInt(usize, n, 10) else 1;
    if (parts.next() != null or (start == 0 and count != 0)) return error.InvalidPatch;
    return .{ .start = if (count == 0) start else start - 1, .count = count };
}

pub fn applyAlloc(alloc: std.mem.Allocator, old: []const u8, patch: []const u8, limit: usize) ![]u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(alloc);
    var it = std.mem.splitScalar(u8, patch, '\n');
    while (it.next()) |line| try lines.append(alloc, line);
    if (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) _ = lines.pop();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var pos: usize = 0;
    var old_line: usize = 0;
    var new_line: usize = 0;
    var idx: usize = 0;
    var hunks: usize = 0;
    if (lines.items.len >= 2 and std.mem.startsWith(u8, lines.items[0], "--- ") and std.mem.startsWith(u8, lines.items[1], "+++ ")) idx = 2;
    while (idx < lines.items.len) {
        const header = lines.items[idx];
        if (!std.mem.startsWith(u8, header, "@@ ")) return error.InvalidPatch;
        var parts = std.mem.tokenizeScalar(u8, header[3..], ' ');
        const before = try range(parts.next() orelse return error.InvalidPatch, '-');
        const after = try range(parts.next() orelse return error.InvalidPatch, '+');
        if (!std.mem.eql(u8, parts.next() orelse return error.InvalidPatch, "@@")) return error.InvalidPatch;
        if (before.start < old_line) return error.InvalidPatch;
        while (old_line < before.start) {
            const line = takeLine(old, &pos) orelse return error.PatchMismatch;
            try out.appendSlice(alloc, line);
            old_line += 1;
            new_line += 1;
        }
        if (after.start != new_line) return error.InvalidPatch;
        idx += 1;
        var removed: usize = 0;
        var added: usize = 0;
        while (idx < lines.items.len and !std.mem.startsWith(u8, lines.items[idx], "@@ ")) : (idx += 1) {
            const line = lines.items[idx];
            if (line.len == 0) return error.InvalidPatch;
            const no_nl = idx + 1 < lines.items.len and std.mem.eql(u8, lines.items[idx + 1], "\\ No newline at end of file");
            switch (line[0]) {
                ' ', '-' => {
                    const source = takeLine(old, &pos) orelse return error.PatchMismatch;
                    const expected = if (no_nl) source else std.mem.trimEnd(u8, source, "\n");
                    if (!std.mem.eql(u8, expected, line[1..]) or (no_nl and std.mem.endsWith(u8, source, "\n"))) return error.PatchMismatch;
                    removed += 1;
                    old_line += 1;
                    if (line[0] == ' ') {
                        try out.appendSlice(alloc, source);
                        added += 1;
                        new_line += 1;
                    }
                },
                '+' => {
                    try out.appendSlice(alloc, line[1..]);
                    if (!no_nl) try out.append(alloc, '\n');
                    added += 1;
                    new_line += 1;
                },
                else => return error.InvalidPatch,
            }
            if (no_nl) idx += 1;
            if (out.items.len > limit) return error.TooLarge;
        }
        if (removed != before.count or added != after.count) return error.InvalidPatch;
        hunks += 1;
    }
    if (hunks == 0) return error.InvalidPatch;
    try out.appendSlice(alloc, old[pos..]);
    if (out.items.len > limit) return error.TooLarge;
    return out.toOwnedSlice(alloc);
}

fn takeLine(text: []const u8, pos: *usize) ?[]const u8 {
    if (pos.* == text.len) return null;
    const start = pos.*;
    pos.* = if (std.mem.indexOfScalarPos(u8, text, start, '\n')) |end| end + 1 else text.len;
    return text[start..pos.*];
}
