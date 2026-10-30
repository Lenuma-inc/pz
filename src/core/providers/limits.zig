//! Subscription quotas reported by the selected provider, never inferred from tokens.
const std = @import("std");

pub const Window = struct {
    used: f64,
    minutes: ?u32 = null,
};

pub const Limits = struct {
    windows: [2]?Window = .{ null, null },
};

pub const CodexWindow = struct {
    used_percent: f64,
    window_minutes: ?u32 = null,
};

pub const CodexLimits = struct {
    primary: ?CodexWindow = null,
    secondary: ?CodexWindow = null,
};

pub fn fromCodex(value: CodexLimits) !?Limits {
    var out: Limits = .{};
    for ([_]?CodexWindow{ value.primary, value.secondary }, 0..) |entry, i| {
        const window = entry orelse continue;
        if (!std.math.isFinite(window.used_percent) or window.used_percent < 0 or window.used_percent > 100 or window.window_minutes == 0) return error.InvalidQuota;
        out.windows[i] = .{ .used = window.used_percent, .minutes = window.window_minutes };
    }
    return if (out.windows[0] == null and out.windows[1] == null) null else out;
}

fn header(bytes: []const u8, name: []const u8) ?[]const u8 {
    var it = std.http.HeaderIterator.init(bytes);
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

fn percent(raw: []const u8, scale: f64) !f64 {
    const n = std.fmt.parseFloat(f64, raw) catch return error.InvalidQuota;
    if (!std.math.isFinite(n) or n < 0 or n > 100 / scale) return error.InvalidQuota;
    return n * scale;
}

pub fn parse(comptime provider: anytype, bytes: []const u8) !?Limits {
    var out: Limits = .{};
    const fields = switch (provider) {
        .openai => .{
            .{ "x-codex-primary-used-percent", "x-codex-primary-window-minutes" },
            .{ "x-codex-secondary-used-percent", "x-codex-secondary-window-minutes" },
        },
        .anthropic => .{
            .{ "anthropic-ratelimit-unified-5h-utilization", "" },
            .{ "anthropic-ratelimit-unified-7d-utilization", "" },
        },
        else => return null,
    };
    inline for (fields, 0..) |pair, i| {
        if (header(bytes, pair[0])) |raw| {
            const minutes: ?u32 = if (provider == .anthropic)
                (if (i == 0) 300 else 10080)
            else if (header(bytes, pair[1])) |v|
                std.fmt.parseUnsigned(u32, v, 10) catch return error.InvalidQuota
            else
                null;
            if (minutes == 0) return error.InvalidQuota;
            out.windows[i] = .{
                .used = try percent(raw, if (provider == .anthropic) 100 else 1),
                .minutes = minutes,
            };
        }
    }
    return if (out.windows[0] == null and out.windows[1] == null) null else out;
}

pub fn format(limits: ?Limits, buf: []u8) ![]const u8 {
    const value = limits orelse return "limits: n/a";
    var w = std.Io.Writer.fixed(buf);
    try w.writeAll("used");
    for (value.windows) |entry| {
        const window = entry orelse continue;
        if (window.minutes) |m| {
            switch (m) {
                300 => try w.writeAll(" 5h"),
                10080 => try w.writeAll(" week"),
                43200 => try w.writeAll(" month"),
                else => try w.print(" {d}m", .{m}),
            }
        } else try w.writeAll(" quota");
        try w.print(":{d:.0}%", .{window.used});
    }
    return w.buffered();
}

test "quota headers preserve actual windows and zero usage" {
    const auth = @import("auth.zig");
    const l = try parse(auth.Provider.openai, "HTTP/1.1 200 OK\r\nX-Codex-Primary-Used-Percent: 0\r\nx-codex-primary-window-minutes: 10080\r\n" ++
        "x-codex-secondary-used-percent: 91.5\r\nx-codex-secondary-window-minutes: 300\r\n\r\n");
    var buf: [128]u8 = undefined;
    try @import("../../test/helpers.zig").expectSnapText(@src(), "used week:0% 5h:92%", try format(l, &buf));
}

test "quota headers scale Claude utilization and handle absent windows" {
    const auth = @import("auth.zig");
    const l = try parse(auth.Provider.anthropic, "HTTP/1.1 200 OK\r\nanthropic-ratelimit-unified-7d-utilization: 0.25\r\n\r\n");
    var buf: [128]u8 = undefined;
    try @import("../../test/helpers.zig").expectSnapText(@src(), "used week:25%", try format(l, &buf));
    try std.testing.expect((try parse(auth.Provider.openai, "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n\r\n")) == null);
    try @import("../../test/helpers.zig").expectSnapText(@src(), "limits: n/a", try format(null, &buf));
}

test "quota headers reject malformed percentages and windows" {
    const auth = @import("auth.zig");
    inline for (.{ "nan", "inf", "-1", "101", "oops" }) |raw| {
        try std.testing.expectError(error.InvalidQuota, parse(auth.Provider.openai, "HTTP/1.1 200 OK\r\nx-codex-primary-used-percent: " ++ raw ++ "\r\n\r\n"));
    }
    try std.testing.expectError(error.InvalidQuota, parse(auth.Provider.anthropic, "HTTP/1.1 200 OK\r\nanthropic-ratelimit-unified-5h-utilization: 1.1\r\n\r\n"));
    try std.testing.expectError(error.InvalidQuota, parse(auth.Provider.openai, "HTTP/1.1 200 OK\r\nx-codex-primary-used-percent: 5\r\nx-codex-primary-window-minutes: 0\r\n\r\n"));
}

test "quota percent property accepts exactly the finite valid range" {
    const zc = @import("zcheck");
    try zc.check(struct {
        fn prop(args: struct { n: i16 }) bool {
            var buf: [32]u8 = undefined;
            const raw = std.fmt.bufPrint(&buf, "{d}", .{args.n}) catch return false;
            const result = percent(raw, 1);
            if (result) |n| return args.n >= 0 and args.n <= 100 and n == @as(f64, @floatFromInt(args.n)) else |err| return err == error.InvalidQuota and (args.n < 0 or args.n > 100);
        }
    }.prop, .{ .iterations = 500 });
}
