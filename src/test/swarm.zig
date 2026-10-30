const std = @import("std");
const swarm = @import("../core/swarm.zig");
const snap = @import("helpers.zig").expectSnapText;
const alloc = std.testing.allocator;

fn check(_: *anyopaque, id: []const u8) !void {
    if (std.mem.eql(u8, id, "blocked")) return error.PolicyDenied;
}

fn invoke(member: *swarm.Member, args: swarm.Args) ![]u8 {
    return member.run(alloc, args, null);
}

fn action(member: *swarm.Member, args: swarm.Args) !void {
    const text = try invoke(member, args);
    defer alloc.free(text);
}

test "swarm peers overlap and exchange objections with authenticated senders" {
    const Exec = struct {
        fn run(_: *anyopaque, ar: std.mem.Allocator, member: *swarm.Member, _: []const u8, out: *std.Io.Writer) !void {
            try std.testing.expectError(error.PolicyDenied, member.run(ar, .{ .op = .spawn, .id = "nested", .prompt = "no" }, null));
            const ready = try member.run(ar, .{ .op = .send, .id = "parent", .text = "ready" }, null);
            defer ar.free(ready);
            const go = try member.run(ar, .{ .op = .recv, .timeout_ms = 2000 }, null);
            defer ar.free(go);
            const peer = std.StaticStringMap([]const u8).initComptime(.{ .{ "a", "b" }, .{ "b", "a" } }).get(member.id).?;
            const sent = try member.run(ar, .{ .op = .send, .id = peer, .text = "objection" }, null);
            defer ar.free(sent);
            const msg = try member.run(ar, .{ .op = .recv, .timeout_ms = 2000 }, null);
            defer ar.free(msg);
            try out.writeAll(msg);
        }
    };
    var ctx: u8 = 0;
    var team: swarm.Team = .{ .alloc = alloc, .ctx = &ctx, .exec = Exec.run, .check = check };
    const parent = team.parent();
    defer team.deinit();
    try action(parent, .{ .op = .spawn, .id = "a", .prompt = "review" });
    try action(parent, .{ .op = .spawn, .id = "b", .prompt = "challenge" });
    try std.testing.expectError(error.DuplicateAgent, invoke(parent, .{ .op = .spawn, .id = "a", .prompt = "again" }));
    try std.testing.expectError(error.AgentBusy, invoke(parent, .{ .op = .close, .id = "a" }));
    // Neither worker can finish until both have announced readiness.
    try action(parent, .{ .op = .recv, .timeout_ms = 2000 });
    try action(parent, .{ .op = .recv, .timeout_ms = 2000 });
    try action(parent, .{ .op = .send, .id = "a", .text = "go" });
    try action(parent, .{ .op = .send, .id = "b", .text = "go" });
    const Result = struct { state: []const u8, text: []const u8, started_ms: i64, ended_ms: i64 };
    const first = try invoke(parent, .{ .op = .wait, .id = "a", .timeout_ms = 2000 });
    defer alloc.free(first);
    const second = try invoke(parent, .{ .op = .wait, .id = "b", .timeout_ms = 2000 });
    defer alloc.free(second);
    const a = try std.json.parseFromSlice(Result, alloc, first, .{ .ignore_unknown_fields = true });
    defer a.deinit();
    const b = try std.json.parseFromSlice(Result, alloc, second, .{ .ignore_unknown_fields = true });
    defer b.deinit();
    try std.testing.expect(a.value.started_ms <= b.value.ended_ms and b.value.started_ms <= a.value.ended_ms);
    try snap(@src(), "done", a.value.state);
    try snap(@src(), "done", b.value.state);
    try snap(@src(), "{\"messages\":[{\"from\":\"b\",\"text\":\"objection\"}]}", a.value.text);
    try snap(@src(), "{\"messages\":[{\"from\":\"a\",\"text\":\"objection\"}]}", b.value.text);
    try std.testing.expectError(error.AgentFinished, invoke(parent, .{ .op = .send, .id = "a", .text = "late" }));
    try action(parent, .{ .op = .close, .id = "a" });
    try std.testing.expectError(error.UnknownAgent, invoke(parent, .{ .op = .wait, .id = "a" }));
}

test "swarm bounds mailboxes and preserves queued messages after overflow" {
    const Exec = struct {
        fn run(_: *anyopaque, _: std.mem.Allocator, _: *swarm.Member, _: []const u8, _: *std.Io.Writer) !void {}
    };
    var ctx: u8 = 0;
    var team: swarm.Team = .{ .alloc = alloc, .ctx = &ctx, .exec = Exec.run, .check = check };
    const parent = team.parent();
    defer team.deinit();
    try std.testing.expectError(error.PolicyDenied, invoke(parent, .{ .op = .spawn, .id = "blocked", .prompt = "no" }));
    for ([_][]const u8{ "", "parent", "a/b", "a\n" }) |id| {
        try std.testing.expectError(error.InvalidArgs, invoke(parent, .{ .op = .spawn, .id = id, .prompt = "no" }));
    }
    try std.testing.expectError(error.UnknownAgent, invoke(parent, .{ .op = .send, .id = "missing", .text = "hello" }));
    try std.testing.expectError(error.Timeout, invoke(parent, .{ .op = .recv, .timeout_ms = 1 }));
    for (0..swarm.max_messages) |_| try action(parent, .{ .op = .send, .id = "parent", .text = "queued" });
    try std.testing.expectError(error.MailboxFull, invoke(parent, .{ .op = .send, .id = "parent", .text = "overflow" }));
    const msg = try invoke(parent, .{ .op = .recv, .timeout_ms = 0 });
    defer alloc.free(msg);
    try snap(@src(), "{\"messages\":[{\"from\":\"parent\",\"text\":\"queued\"}]}", msg);
    try action(parent, .{ .op = .send, .id = "parent", .text = "after drain" });
}

test "swarm stop interrupts waiting peers and teardown joins every worker" {
    const Exec = struct {
        exited: std.atomic.Value(usize) = .init(0),
        fn run(ctx: *anyopaque, ar: std.mem.Allocator, member: *swarm.Member, _: []const u8, _: *std.Io.Writer) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            defer _ = self.exited.fetchAdd(1, .release);
            const result = try member.run(ar, .{ .op = .recv, .timeout_ms = 300000 }, null);
            ar.free(result);
        }
    };
    var ctx = Exec{};
    var team: swarm.Team = .{ .alloc = alloc, .ctx = &ctx, .exec = Exec.run, .check = check };
    const parent = team.parent();
    {
        defer team.deinit();
        try action(parent, .{ .op = .spawn, .id = "a", .prompt = "wait" });
        try action(parent, .{ .op = .spawn, .id = "b", .prompt = "wait" });
        try action(parent, .{ .op = .stop, .id = "a" });
        const result = try invoke(parent, .{ .op = .wait, .id = "a", .timeout_ms = 2000 });
        defer alloc.free(result);
        const parsed = try std.json.parseFromSlice(struct { state: []const u8, err: []const u8 }, alloc, result, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try snap(@src(), "canceled", parsed.value.state);
        try snap(@src(), "Canceled", parsed.value.err);
    }
    try std.testing.expectEqual(@as(usize, 2), ctx.exited.load(.acquire));
}

test "swarm mock-terminal renders tool exchange and synthesis" {
    const Ui = @import("../modes/tui/harness.zig").Ui;
    const VScreen = @import("../modes/tui/vscreen.zig").VScreen;
    var ui = try Ui.init(alloc, 80, 16, "test-model", "test-provider");
    defer ui.deinit();
    try ui.onProvider(.{ .tool_call = .{ .id = "s1", .name = "swarm", .args = "{\"op\":\"spawn\",\"id\":\"critic\",\"prompt\":\"challenge\"}" } });
    try ui.onProvider(.{ .tool_result = .{ .id = "s1", .output = "{\"id\":\"critic\",\"state\":\"running\"}", .is_err = false } });
    try ui.onProvider(.{ .tool_call = .{ .id = "s2", .name = "swarm", .args = "{\"op\":\"send\",\"id\":\"critic\",\"text\":\"proposal=41\"}" } });
    try ui.onProvider(.{ .tool_result = .{ .id = "s2", .output = "{\"sent\":true}", .is_err = false } });
    try ui.onProvider(.{ .text = "SWARM_COMPLETE" });
    var screen = try VScreen.init(alloc, 80, 16);
    defer screen.deinit();
    var buf: [32768]u8 = undefined;
    var out = @import("../modes/tui/test_buf.zig").TestBuf.init(&buf);
    try ui.draw(&out);
    screen.feed(out.view());
    var found_tool = false;
    var found_result = false;
    for (0..11) |row| {
        const text = try screen.rowText(alloc, row);
        defer alloc.free(text);
        found_tool = found_tool or std.mem.indexOf(u8, text, "swarm") != null;
        found_result = found_result or std.mem.indexOf(u8, text, "SWARM_COMPLETE") != null;
    }
    const summary = try std.fmt.allocPrint(alloc, "swarm={any}\nresult={any}", .{ found_tool, found_result });
    defer alloc.free(summary);
    try snap(@src(), "swarm=true\nresult=true", summary);
}
