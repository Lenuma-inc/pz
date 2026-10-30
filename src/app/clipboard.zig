//! Clipboard transport chosen from the active desktop session, without shell interpolation.
const std = @import("std");
const builtin = @import("builtin");
const sys = @import("pz_io");
const attach = @import("../core/attach.zig");

pub const Backend = enum {
    wayland,
    x11,
    mac,

    pub fn command(self: Backend) []const u8 {
        return switch (self) {
            .wayland => "wl-paste",
            .x11 => "xclip",
            .mac => "osascript",
        };
    }
};

pub fn backend(wayland: ?[]const u8, display: ?[]const u8) !Backend {
    if (builtin.os.tag == .macos) return .mac;
    if (wayland) |value| if (value.len != 0) return .wayland;
    if (display) |value| if (value.len != 0) return .x11;
    return error.ClipboardSessionUnavailable;
}

pub const Content = struct {
    data: []u8,
    ext: ?[]const u8,
};

const Format = struct { mime: []const u8, ext: []const u8 };
const images = [_]Format{
    .{ .mime = "image/png", .ext = ".png" },
    .{ .mime = "image/jpeg", .ext = ".jpg" },
    .{ .mime = "image/webp", .ext = ".webp" },
    .{ .mime = "image/gif", .ext = ".gif" },
};

fn selectImage(types: []const u8) ?Format {
    for (images) |format| {
        var lines = std.mem.tokenizeAny(u8, types, "\r\n");
        while (lines.next()) |line| {
            if (std.mem.eql(u8, std.mem.trim(u8, line, " \t"), format.mime)) return format;
        }
    }
    return null;
}

pub fn readAlloc(alloc: std.mem.Allocator, source: Backend) !Content {
    const types = try runAlloc(alloc, switch (source) {
        .wayland => &.{ "wl-paste", "--list-types" },
        .x11 => &.{ "xclip", "-selection", "clipboard", "-out", "-target", "TARGETS" },
        .mac => &.{ "osascript", "-e", "try\nget the clipboard as «class PNGf»\nreturn \"image/png\"\non error\nreturn \"text/plain\"\nend try" },
    });
    defer alloc.free(types);
    const format = selectImage(types);
    const mime = if (format) |f| f.mime else "text/plain";
    var data = try runAlloc(alloc, switch (source) {
        .wayland => &.{ "wl-paste", "--no-newline", "--type", mime },
        .x11 => &.{ "xclip", "-selection", "clipboard", "-out", "-target", if (format != null) mime else "UTF8_STRING" },
        .mac => if (format != null)
            &.{ "osascript", "-e", "get the clipboard as «class PNGf»" }
        else
            &.{ "osascript", "-e", "get the clipboard as text" },
    });
    errdefer alloc.free(data);
    if (source == .mac and format != null) {
        const raw = std.mem.trim(u8, data, " \t\r\n");
        const prefix = "«data PNGf";
        if (!std.mem.startsWith(u8, raw, prefix) or !std.mem.endsWith(u8, raw, "»")) return error.InvalidClipboardImage;
        const hex = raw[prefix.len .. raw.len - "»".len];
        const decoded = try alloc.alloc(u8, hex.len / 2);
        errdefer alloc.free(decoded);
        _ = try std.fmt.hexToBytes(decoded, hex);
        alloc.free(data);
        data = decoded;
    }
    if (data.len == 0) return error.ClipboardEmpty;
    if (format == null and !std.unicode.utf8ValidateSlice(data)) return error.InvalidClipboardText;
    if (format) |f| if (!attach.isImage(data, f.mime)) return error.InvalidClipboardImage;
    return .{ .data = data, .ext = if (format) |f| f.ext else null };
}

fn runAlloc(alloc: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    const result = std.process.run(alloc, sys.io, .{
        .argv = argv,
        .stdout_limit = .limited(attach.max_bytes * 2 + 128),
        .stderr_limit = .limited(1024),
    }) catch |err| return switch (err) {
        error.FileNotFound => error.ClipboardToolUnavailable,
        else => err,
    };
    defer alloc.free(result.stderr);
    errdefer alloc.free(result.stdout);
    if (result.term != .exited or result.term.exited != 0) return error.ClipboardReadFailed;
    return result.stdout;
}

test "clipboard MIME negotiation prefers exact supported images" {
    try std.testing.expectEqualStrings(".png", selectImage("text/plain\nimage/jpeg\nimage/png\n").?.ext);
    try std.testing.expectEqualStrings(".jpg", selectImage("image/jpeg\r\n").?.ext);
    try std.testing.expect(selectImage("text/plain\napplication/image/png-fake\n") == null);
    if (builtin.os.tag != .macos) {
        try std.testing.expect((try backend("wayland-0", ":0")) == .wayland);
        try std.testing.expect((try backend(null, ":0")) == .x11);
        try std.testing.expectError(error.ClipboardSessionUnavailable, backend(null, null));
    }
}
