//! Local-only review of context instructions; no model sees the preview.
const std = @import("std");
const overlay = @import("overlay.zig");
const editor = @import("editor.zig");
const utf8 = @import("../../core/utf8.zig");

pub const Review = struct {
    ov: overlay.Overlay,

    pub fn init(alloc: std.mem.Allocator, path: []const u8, content: []const u8) !Review {
        return initChange(alloc, path, content, "Trust AGENTS.md?", "Trust this exact file");
    }

    pub fn initChange(alloc: std.mem.Allocator, path: []const u8, content: []const u8, title: []const u8, action: []const u8) !Review {
        var rows: std.ArrayList([]u8) = .empty;
        errdefer {
            for (rows.items) |row| alloc.free(row);
            rows.deinit(alloc);
        }
        try appendRow(alloc, &rows, "Deny");
        try appendRow(alloc, &rows, action);
        try appendPreview(alloc, &rows, path);
        try appendRow(alloc, &rows, "--- Contents (quoted; controls escaped) ---");
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| try appendPreview(alloc, &rows, line);
        var ov = overlay.Overlay.initDyn(try rows.toOwnedSlice(alloc), title, .session);
        ov.hint = "Up/Down review; Enter chooses; Esc denies";
        return .{ .ov = ov };
    }

    pub fn deinit(self: *Review, alloc: std.mem.Allocator) void {
        self.ov.deinit(alloc);
    }

    pub fn onKey(self: *Review, key: editor.Key) ?bool {
        switch (key) {
            .up => self.ov.up(),
            .down => self.ov.down(),
            .page_up => for (0..12) |_| self.ov.up(),
            .page_down => for (0..12) |_| self.ov.down(),
            .enter => switch (self.ov.sel) {
                0 => return false,
                1 => return true,
                else => {}, // preview rows cannot grant trust
            },
            .esc, .ctrl_c => return false,
            else => {}, // typing cannot accept instructions
        }
        return null;
    }
};

pub fn run(alloc: std.mem.Allocator, ui: *@import("harness.zig").Ui, out: *std.Io.Writer, reader: *@import("input.zig").Reader, path: []const u8, content: []const u8, title: []const u8, action: []const u8) !bool {
    var view = try Review.initChange(alloc, path, content, title, action);
    defer view.deinit(alloc);
    const saved = ui.ov;
    defer ui.ov = saved;
    while (true) {
        ui.ov = view.ov;
        try ui.draw(out);
        switch (reader.next()) {
            .key => |key| if (view.onKey(key)) |allowed| return allowed,
            .err => return error.ApprovalRequired,
            else => {}, // pasted text and notifications cannot grant approval
        }
    }
}

fn appendRow(alloc: std.mem.Allocator, rows: *std.ArrayList([]u8), text: []const u8) !void {
    const copy = try alloc.dupe(u8, text);
    errdefer alloc.free(copy);
    try rows.append(alloc, copy);
}

fn appendPreview(alloc: std.mem.Allocator, rows: *std.ArrayList([]u8), raw: []const u8) !void {
    const safe = try utf8.Lossy.init(alloc, raw);
    defer if (safe.owned) |owned| alloc.free(owned);
    const quoted = try std.json.Stringify.valueAlloc(alloc, safe.text, .{});
    defer alloc.free(quoted);
    var rest: []const u8 = quoted;
    while (rest.len > 0) {
        var n = @min(rest.len, 56);
        while (n < rest.len and rest[n] & 0xc0 == 0x80) n -= 1;
        try appendRow(alloc, rows, rest[0..n]);
        rest = rest[n..];
    }
}

test "context review defaults to deny and previews escaped instructions" {
    const alloc = std.testing.allocator;
    var review = try Review.init(alloc, "/Downloads/AGENTS.md", "Change config\n\x1b]52;c;secret\x07");
    defer review.deinit(alloc);
    var ui = try @import("harness.zig").Ui.init(alloc, 80, 24, "model", "provider");
    defer ui.deinit();
    ui.ov = review.ov;
    defer ui.ov = null;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try ui.draw(&out.writer);
    try std.testing.expect(out.written().len > 0);
    var screen = try @import("vscreen.zig").VScreen.init(alloc, 80, 24);
    defer screen.deinit();
    screen.feed(out.written());
    var rendered_title = false;
    var rendered_content = false;
    for (0..screen.h) |r| {
        const row = try screen.rowText(alloc, r);
        defer alloc.free(row);
        rendered_title = rendered_title or std.mem.indexOf(u8, row, "Trust AGENTS.md?") != null;
        rendered_content = rendered_content or std.mem.indexOf(u8, row, "Change config") != null;
    }
    const snap = try std.fmt.allocPrint(alloc, "default={?} path={} content={} controls_escaped={} rendered={}", .{
        review.onKey(.enter),
        std.mem.eql(u8, review.ov.dyn_items.?[2], "\"/Downloads/AGENTS.md\""),
        std.mem.eql(u8, review.ov.dyn_items.?[4], "\"Change config\""),
        std.mem.indexOf(u8, review.ov.dyn_items.?[5], "\\u001b") != null and std.mem.indexOfScalar(u8, review.ov.dyn_items.?[5], 27) == null,
        rendered_title and rendered_content,
    });
    defer alloc.free(snap);
    try @import("ohsnap").default.snap(@src(),
        \\[]u8
        \\  "default=false path=true content=true controls_escaped=true rendered=true"
    ).expectEqual(snap);
    _ = review.onKey(.down);
    try std.testing.expect(review.onKey(.enter).?);
    try std.testing.expect(!review.onKey(.esc).?);
}
