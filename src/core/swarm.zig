//! Session-local workers and addressed live mailboxes.
const std = @import("std");
const sys = @import("pz_io");
const providers = @import("providers/api.zig");
const audit = @import("audit.zig");
const tools = @import("tools.zig");

pub const max_workers = 8;
pub const max_messages = 64;
pub const max_text = 16 * 1024;
pub const max_message = 4096;

pub const Args = struct {
    op: enum { spawn, send, recv, wait, stop, close, list },
    id: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    text: ?[]const u8 = null,
    timeout_ms: u32 = 30000,
};

const Message = struct {
    from: []u8,
    text: []u8,
};

pub const Member = struct {
    team: *Team,
    id: []const u8,
    worker: ?*Worker = null,
    canceled: std.atomic.Value(bool) = .init(false),
    abort: providers.AbortSlot = .{},
    inbox: std.ArrayList(Message) = .empty,

    pub fn isCanceled(self: *const Member) bool {
        return self.canceled.load(.acquire);
    }

    fn clear(self: *Member) void {
        for (self.inbox.items) |msg| {
            self.team.alloc.free(msg.from);
            self.team.alloc.free(msg.text);
        }
        self.inbox.deinit(self.team.alloc);
    }

    pub fn run(self: *Member, alloc: std.mem.Allocator, args: Args, cancel: ?*tools.CancelSrc) ![]u8 {
        if (args.timeout_ms > 300000) return error.InvalidArgs;
        return switch (args.op) {
            .spawn => blk: {
                if (self.worker != null) return error.PolicyDenied;
                try self.team.spawn(args.id orelse return error.InvalidArgs, args.prompt orelse return error.InvalidArgs);
                break :blk std.json.Stringify.valueAlloc(alloc, .{ .id = args.id.?, .state = "running" }, .{});
            },
            .send => blk: {
                try self.team.send(self, args.id orelse return error.InvalidArgs, args.text orelse return error.InvalidArgs);
                break :blk alloc.dupe(u8, "{\"sent\":true}");
            },
            .recv => self.team.recv(self, alloc, args.timeout_ms, cancel),
            .wait => self.team.wait(self, alloc, args.id orelse return error.InvalidArgs, args.timeout_ms, cancel),
            .list => self.team.list(alloc),
            .stop => blk: {
                if (self.worker != null) return error.PolicyDenied;
                try self.team.stop(args.id orelse return error.InvalidArgs);
                break :blk alloc.dupe(u8, "{\"stop_requested\":true}");
            },
            .close => blk: {
                if (self.worker != null) return error.PolicyDenied;
                try self.team.close(args.id orelse return error.InvalidArgs);
                break :blk alloc.dupe(u8, "{\"closed\":true}");
            },
        };
    }
};

const Worker = struct {
    member: Member,
    prompt: []u8,
    thread: ?std.Thread = null,
    state: enum { running, done, failed, canceled } = .running,
    output: ?[]u8 = null,
    truncated: bool = false,
    err: ?anyerror = null,
    started_ms: i64,
    ended_ms: ?i64 = null,

    fn run(self: *Worker) void {
        const team = self.member.team;
        var arena = std.heap.ArenaAllocator.init(team.alloc);
        defer arena.deinit();
        var out = std.Io.Writer.Allocating.init(arena.allocator());
        defer out.deinit();
        var failure: ?anyerror = null;
        team.exec(team.ctx, arena.allocator(), &self.member, self.prompt, &out.writer) catch |err| {
            failure = err;
        };
        team.mu.lockUncancelable(sys.io);
        defer team.mu.unlock(sys.io);
        const safe = audit.redactTextAlloc(team.alloc, out.written(), .@"pub") catch |err| {
            self.err = err;
            self.state = .failed;
            self.ended_ms = sys.nowMs();
            return;
        };
        defer team.alloc.free(safe);
        const kept = tools.truncate.apply(safe, 8192);
        self.truncated = kept.truncated;
        self.output = team.alloc.dupe(u8, kept.chunk) catch |err| {
            self.err = err;
            self.state = .failed;
            self.ended_ms = sys.nowMs();
            return;
        };
        self.err = failure;
        self.state = if (self.member.isCanceled()) .canceled else if (failure != null) .failed else .done;
        self.ended_ms = sys.nowMs();
    }
};

pub const Team = struct {
    /// Must be safe for concurrent worker allocations.
    alloc: std.mem.Allocator,
    ctx: *anyopaque,
    exec: *const fn (*anyopaque, std.mem.Allocator, *Member, []const u8, *std.Io.Writer) anyerror!void,
    check: *const fn (*anyopaque, []const u8) anyerror!void,
    mu: std.Io.Mutex = .init,
    workers: [max_workers]?*Worker = @splat(null),
    root: Member = undefined,

    pub fn parent(self: *Team) *Member {
        self.root = .{ .team = self, .id = "parent" };
        return &self.root;
    }

    pub fn deinit(self: *Team) void {
        for (self.workers) |maybe| if (maybe) |w| {
            w.member.canceled.store(true, .release);
            w.member.abort.abort();
        };
        for (self.workers) |maybe| if (maybe) |w| {
            if (w.thread) |thread| thread.join();
        };
        for (&self.workers) |*slot| if (slot.*) |w| {
            self.free(w);
            slot.* = null;
        };
        self.root.clear();
    }

    fn free(self: *Team, w: *Worker) void {
        w.member.clear();
        self.alloc.free(w.member.id);
        self.alloc.free(w.prompt);
        if (w.output) |output| self.alloc.free(output);
        self.alloc.destroy(w);
    }

    fn find(self: *Team, id: []const u8) ?*Worker {
        for (self.workers) |maybe| if (maybe) |w| {
            if (std.mem.eql(u8, id, w.member.id)) return w;
        };
        return null;
    }

    fn spawn(self: *Team, id: []const u8, prompt: []const u8) !void {
        if (id.len == 0 or id.len > 64 or std.mem.eql(u8, id, "parent") or prompt.len == 0 or prompt.len > max_text) return error.InvalidArgs;
        for (id) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return error.InvalidArgs;
        try self.check(self.ctx, id);
        self.mu.lockUncancelable(sys.io);
        defer self.mu.unlock(sys.io);
        if (self.find(id) != null) return error.DuplicateAgent;
        for (&self.workers) |*slot| if (slot.* == null) {
            const w = try self.alloc.create(Worker);
            errdefer self.alloc.destroy(w);
            const name = try self.alloc.dupe(u8, id);
            errdefer self.alloc.free(name);
            const task = try self.alloc.dupe(u8, prompt);
            errdefer self.alloc.free(task);
            w.* = .{ .member = .{ .team = self, .id = name }, .prompt = task, .started_ms = sys.nowMs() };
            w.member.worker = w;
            w.thread = try std.Thread.spawn(.{}, Worker.run, .{w});
            slot.* = w;
            return;
        };
        return error.AgentLimit;
    }

    fn send(self: *Team, from: *Member, id: []const u8, text: []const u8) !void {
        if (text.len == 0 or text.len > max_message) return error.InvalidArgs;
        self.mu.lockUncancelable(sys.io);
        defer self.mu.unlock(sys.io);
        const to = if (std.mem.eql(u8, id, "parent")) &self.root else blk: {
            const w = self.find(id) orelse return error.UnknownAgent;
            if (w.state != .running) return error.AgentFinished;
            break :blk &w.member;
        };
        if (to.inbox.items.len >= max_messages) return error.MailboxFull;
        const sender = try self.alloc.dupe(u8, from.id);
        errdefer self.alloc.free(sender);
        const body = try audit.redactTextAlloc(self.alloc, text, .@"pub");
        errdefer self.alloc.free(body);
        try to.inbox.append(self.alloc, .{ .from = sender, .text = body });
    }

    fn pause(member: *Member, deadline: i64, cancel: ?*tools.CancelSrc) !void {
        if (member.isCanceled() or if (cancel) |flag| flag.isCanceled() else false) return error.Canceled;
        if (sys.nowMs() >= deadline) return error.Timeout;
        try std.Io.sleep(sys.io, .fromMilliseconds(5), .awake);
    }

    fn recv(self: *Team, member: *Member, alloc: std.mem.Allocator, timeout_ms: u32, cancel: ?*tools.CancelSrc) ![]u8 {
        const deadline = sys.nowMs() + timeout_ms;
        while (true) {
            self.mu.lockUncancelable(sys.io);
            if (member.inbox.items.len > 0 or timeout_ms == 0) {
                defer self.mu.unlock(sys.io);
                const count = @min(member.inbox.items.len, 1);
                const json = try std.json.Stringify.valueAlloc(alloc, .{ .messages = member.inbox.items[0..count] }, .{});
                if (count > 0) {
                    const msg = member.inbox.orderedRemove(0);
                    self.alloc.free(msg.from);
                    self.alloc.free(msg.text);
                }
                return json;
            }
            self.mu.unlock(sys.io);
            try pause(member, deadline, cancel);
        }
    }

    fn wait(self: *Team, member: *Member, alloc: std.mem.Allocator, id: []const u8, timeout_ms: u32, cancel: ?*tools.CancelSrc) ![]u8 {
        if (std.mem.eql(u8, member.id, id)) return error.InvalidArgs;
        const deadline = sys.nowMs() + timeout_ms;
        while (true) {
            self.mu.lockUncancelable(sys.io);
            const w = self.find(id) orelse {
                self.mu.unlock(sys.io);
                return error.UnknownAgent;
            };
            if (w.state != .running) {
                defer self.mu.unlock(sys.io);
                return std.json.Stringify.valueAlloc(alloc, .{ .id = w.member.id, .state = w.state, .text = w.output, .truncated = w.truncated, .err = if (w.err) |err| @errorName(err) else null, .started_ms = w.started_ms, .ended_ms = w.ended_ms }, .{});
            }
            self.mu.unlock(sys.io);
            try pause(member, deadline, cancel);
        }
    }

    fn list(self: *Team, alloc: std.mem.Allocator) ![]u8 {
        self.mu.lockUncancelable(sys.io);
        defer self.mu.unlock(sys.io);
        const Info = struct { id: []const u8, state: @FieldType(Worker, "state") };
        var items: [max_workers]Info = undefined;
        var len: usize = 0;
        for (self.workers) |maybe| if (maybe) |w| {
            items[len] = .{ .id = w.member.id, .state = w.state };
            len += 1;
        };
        return std.json.Stringify.valueAlloc(alloc, items[0..len], .{});
    }

    fn stop(self: *Team, id: []const u8) !void {
        self.mu.lockUncancelable(sys.io);
        defer self.mu.unlock(sys.io);
        const w = self.find(id) orelse return error.UnknownAgent;
        w.member.canceled.store(true, .release);
        w.member.abort.abort();
    }

    fn close(self: *Team, id: []const u8) !void {
        self.mu.lockUncancelable(sys.io);
        defer self.mu.unlock(sys.io);
        for (&self.workers) |*slot| if (slot.*) |w| {
            if (!std.mem.eql(u8, id, w.member.id)) continue;
            if (w.state == .running) return error.AgentBusy;
            if (w.thread) |thread| thread.join();
            self.free(w);
            slot.* = null;
            return;
        };
        return error.UnknownAgent;
    }
};
