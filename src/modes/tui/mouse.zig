//! Mouse event types: scroll, press, release.
const std = @import("std");

pub const Event = union(enum) {
    scroll_up,
    scroll_down,
    press: Pos,
    motion: Pos,
    release: Pos,

    pub const Pos = struct {
        x: usize,
        y: usize,
        btn: u8,
    };
};

pub const Result = struct {
    ev: Event,
    len: usize,
};

const ParseSnap = struct {
    scroll_up: Result,
    scroll_down: Result,
    press: Result,
    release: Result,
    consumed_len: Result,
};

/// Parse SGR mouse sequence: \x1b[<btn;x;yM or \x1b[<btn;x;ym
pub fn parse(buf: []const u8) ?Result {
    if (buf.len < 6) return null;
    if (buf[0] != '\x1b' or buf[1] != '[' or buf[2] != '<') return null;

    var i: usize = 3;
    const btn = parseNum(buf, &i) orelse return null;
    if (i >= buf.len or buf[i] != ';') return null;
    i += 1;
    const x = parseNum(buf, &i) orelse return null;
    if (i >= buf.len or buf[i] != ';') return null;
    i += 1;
    const y = parseNum(buf, &i) orelse return null;
    if (i >= buf.len) return null;

    const final = buf[i];
    if (final != 'M' and final != 'm') return null;
    i += 1;

    const is_press = final == 'M';
    const pos = Event.Pos{
        .x = if (x > 0) x - 1 else 0,
        .y = if (y > 0) y - 1 else 0,
        .btn = @intCast(btn & 3),
    };
    const ev: Event = if (btn & 64 != 0) switch (btn & 1) {
        0 => .scroll_up,
        else => .scroll_down,
    } else if (btn & 32 != 0) .{ .motion = pos } else if (is_press) .{ .press = pos } else .{
        .release = pos,
    };

    return .{ .ev = ev, .len = i };
}

fn parseNum(buf: []const u8, pos: *usize) ?usize {
    var i = pos.*;
    if (i >= buf.len or buf[i] < '0' or buf[i] > '9') return null;
    var val: usize = 0;
    while (i < buf.len and buf[i] >= '0' and buf[i] <= '9') {
        val = val * 10 + @as(usize, buf[i] - '0');
        i += 1;
    }
    pos.* = i;
    return val;
}

// ============================================================
// Tests
// ============================================================

test "parse snapshots are stable" {
    const OhSnap = @import("ohsnap");
    const oh = OhSnap.default;

    const snap = ParseSnap{
        .scroll_up = parse("\x1b[<64;10;5M").?,
        .scroll_down = parse("\x1b[<65;1;1M").?,
        .press = parse("\x1b[<0;5;10M").?,
        .release = parse("\x1b[<0;3;7m").?,
        .consumed_len = parse("\x1b[<64;1;1Mtrailing").?,
    };

    try oh.snap(@src(),
        \\modes.tui.mouse.ParseSnap
        \\  .scroll_up: modes.tui.mouse.Result
        \\    .ev: modes.tui.mouse.Event
        \\      .scroll_up: void = void
        \\    .len: usize = 11
        \\  .scroll_down: modes.tui.mouse.Result
        \\    .ev: modes.tui.mouse.Event
        \\      .scroll_down: void = void
        \\    .len: usize = 10
        \\  .press: modes.tui.mouse.Result
        \\    .ev: modes.tui.mouse.Event
        \\      .press: modes.tui.mouse.Event.Pos
        \\        .x: usize = 4
        \\        .y: usize = 9
        \\        .btn: u8 = 0
        \\    .len: usize = 10
        \\  .release: modes.tui.mouse.Result
        \\    .ev: modes.tui.mouse.Event
        \\      .release: modes.tui.mouse.Event.Pos
        \\        .x: usize = 2
        \\        .y: usize = 6
        \\        .btn: u8 = 0
        \\    .len: usize = 9
        \\  .consumed_len: modes.tui.mouse.Result
        \\    .ev: modes.tui.mouse.Event
        \\      .scroll_up: void = void
        \\    .len: usize = 10
    ).expectEqual(snap);
}

test "parse returns null on short buf" {
    try std.testing.expect(parse("\x1b[<") == null);
    try std.testing.expect(parse("") == null);
    try std.testing.expect(parse("\x1b") == null);
}

test "parse returns null on bad prefix" {
    try std.testing.expect(parse("hello world") == null);
}

test "parse returns null on missing final" {
    try std.testing.expect(parse("\x1b[<0;1;1") == null);
}

test "parse reports drag motion separately from wheel events" {
    const got = parse("\x1b[<32;5;10M").?.ev;
    switch (got) {
        .motion => |pos| {
            try std.testing.expectEqual(@as(usize, 4), pos.x);
            try std.testing.expectEqual(@as(usize, 9), pos.y);
            try std.testing.expectEqual(@as(u8, 0), pos.btn);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse returns null on bad final char" {
    try std.testing.expect(parse("\x1b[<0;1;1X") == null);
}
