//! MCP stdio client. Configured programs are trusted executable configuration.
const std = @import("std");
const sys = @import("pz_io");
const tools = @import("tools.zig");
const sandbox = @import("sandbox.zig");
const time = @import("time.zig");

pub const max_tools = 256;
const max_frame = 1024 * 1024;
const max_servers = 16;

pub const Server = struct {
    command: []const u8 = "",
    url: ?[]const u8 = null,
    headers: ?std.json.Value = null,
    args: []const []const u8 = &.{},
    env: ?std.json.Value = null,
    enabled: bool = true,
    timeout_ms: u32 = 30000,
};

fn identifier(s: []const u8) bool {
    if (s.len == 0 or s.len > 128) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    return true;
}

pub fn validate(raw: std.json.Value) !void {
    if (raw != .object or raw.object.count() > max_servers) return error.InvalidMcpConfig;
    var it = raw.object.iterator();
    while (it.next()) |kv| {
        if (!identifier(kv.key_ptr.*)) return error.InvalidMcpConfig;
        const parsed = try std.json.parseFromValue(Server, std.heap.page_allocator, kv.value_ptr.*, .{});
        defer parsed.deinit();
        const s = parsed.value;
        if ((s.command.len == 0) == (s.url == null) or std.mem.indexOfScalar(u8, s.command, 0) != null or s.timeout_ms == 0 or s.timeout_ms > 300000) return error.InvalidMcpConfig;
        if (s.url) |url| {
            _ = tools.web.parseUrl(url) catch return error.InvalidMcpConfig;
            if (s.args.len != 0 or s.env != null) return error.InvalidMcpConfig;
        } else if (s.headers != null) return error.InvalidMcpConfig;
        if (s.headers) |headers| {
            if (headers != .object) return error.InvalidMcpConfig;
            var hdrs = headers.object.iterator();
            while (hdrs.next()) |h| {
                if (h.key_ptr.len == 0 or h.value_ptr.* != .string or std.mem.indexOfAny(u8, h.value_ptr.string, "\r\n\x00") != null) return error.InvalidMcpConfig;
                for (h.key_ptr.*) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", c) == null) return error.InvalidMcpConfig;
                for ([_][]const u8{ "Host", "Content-Length", "Transfer-Encoding", "Content-Type", "Accept", "Mcp-Session-Id", "MCP-Protocol-Version" }) |reserved| {
                    if (std.ascii.eqlIgnoreCase(h.key_ptr.*, reserved)) return error.InvalidMcpConfig;
                }
            }
        }
        for (s.args) |arg| if (std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidMcpConfig;
        if (s.env) |env| {
            if (env != .object) return error.InvalidMcpConfig;
            var vars = env.object.iterator();
            while (vars.next()) |v| {
                if (v.key_ptr.len == 0 or std.mem.indexOfAny(u8, v.key_ptr.*, "=\x00") != null or v.value_ptr.* != .string) return error.InvalidMcpConfig;
                if (std.mem.indexOfScalar(u8, v.value_ptr.string, 0) != null) return error.InvalidMcpConfig;
            }
        }
    }
}

const Client = struct {
    alloc: std.mem.Allocator,
    child: std.process.Child,
    timeout_ms: u32,
    pending: std.ArrayList(u8) = .empty,
    next_id: i64 = 0,
    closed: bool = false,

    fn init(alloc: std.mem.Allocator, server: Server) !Client {
        const argv = try alloc.alloc([]const u8, server.args.len + 1);
        defer alloc.free(argv);
        argv[0] = server.command;
        @memcpy(argv[1..], server.args);
        var count: usize = 0;
        while (std.c.environ[count] != null) : (count += 1) {}
        var env = try std.process.Environ.createMap(.{ .block = .{ .slice = std.c.environ[0..count :null] } }, alloc);
        defer env.deinit();
        sandbox.scrubEnv(&env);
        if (server.env) |values| {
            var it = values.object.iterator();
            while (it.next()) |kv| try env.put(kv.key_ptr.*, kv.value_ptr.string);
        }
        var child = try std.process.spawn(sys.io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            // Server diagnostics must not corrupt the TUI or block on an undrained pipe.
            // Protocol and startup failures still propagate through the MCP status/report.
            .stderr = .ignore,
            .environ_map = &env,
            .pgid = 0,
        });
        errdefer child.kill(sys.io);
        try nonblock(child.stdin.?.handle);
        try nonblock(child.stdout.?.handle);
        return .{ .alloc = alloc, .child = child, .timeout_ms = server.timeout_ms };
    }

    fn close(self: *Client) void {
        if (self.closed) return;
        // Also stop descendants which inherited protocol pipes.
        if (self.child.id) |pid| std.posix.kill(-pid, std.posix.SIG.KILL) catch {};
        self.child.kill(sys.io);
        self.closed = true;
    }

    fn deinit(self: *Client) void {
        self.close();
        self.pending.deinit(self.alloc);
    }

    fn ready(self: *Client, fd: std.posix.fd_t, events: i16, deadline: i64, cancel: ?*tools.CancelSrc) !void {
        while (true) {
            if (cancel) |c| if (c.isCanceled()) return error.McpCancelled;
            const remaining = deadline - time.milliTimestamp();
            if (remaining <= 0) return error.McpTimeout;
            var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
            if (try std.posix.poll(&fds, @intCast(@min(remaining, 25))) != 0) return;
            if (self.closed) return error.McpClosed;
        }
    }

    fn send(self: *Client, value: anytype, deadline: i64, cancel: ?*tools.CancelSrc) !void {
        const json = try std.json.Stringify.valueAlloc(self.alloc, value, .{});
        defer self.alloc.free(json);
        if (json.len > max_frame) return error.McpFrameTooLarge;
        const frame = try std.fmt.allocPrint(self.alloc, "{s}\n", .{json});
        defer self.alloc.free(frame);
        var at: usize = 0;
        while (at < frame.len) {
            try self.ready(self.child.stdin.?.handle, std.posix.POLL.OUT, deadline, cancel);
            const n = std.c.write(self.child.stdin.?.handle, frame[at..].ptr, frame.len - at);
            switch (std.posix.errno(n)) {
                .SUCCESS => {},
                .AGAIN, .INTR => continue,
                .PIPE => return error.McpClosed,
                else => return error.McpIo,
            }
            if (n == 0) return error.McpClosed;
            at += @intCast(n);
        }
    }

    fn receive(self: *Client, deadline: i64, cancel: ?*tools.CancelSrc) !std.json.Parsed(std.json.Value) {
        while (true) {
            if (std.mem.indexOfScalar(u8, self.pending.items, '\n')) |end| {
                const parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, self.pending.items[0..end], .{ .allocate = .alloc_always, .max_value_len = max_frame });
                const rest = self.pending.items.len - end - 1;
                std.mem.copyForwards(u8, self.pending.items[0..rest], self.pending.items[end + 1 ..]);
                self.pending.items.len = rest;
                return parsed;
            }
            try self.ready(self.child.stdout.?.handle, std.posix.POLL.IN, deadline, cancel);
            var buf: [4096]u8 = undefined;
            const n = std.posix.read(self.child.stdout.?.handle, &buf) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
            if (n == 0) return error.McpClosed;
            if (self.pending.items.len + n > max_frame) return error.McpFrameTooLarge;
            try self.pending.appendSlice(self.alloc, buf[0..n]);
        }
    }

    fn request(self: *Client, method: []const u8, params: anytype, cancel: ?*tools.CancelSrc) !std.json.Parsed(std.json.Value) {
        if (self.closed) return error.McpClosed;
        // A failed exchange invalidates the stream; never consume a stale reply on a later call.
        errdefer self.close();
        self.next_id += 1;
        const id = self.next_id;
        const deadline = time.milliTimestamp() + self.timeout_ms;
        try self.send(.{ .jsonrpc = "2.0", .id = id, .method = method, .params = params }, deadline, cancel);
        var messages: usize = 0;
        while (messages < 1024) : (messages += 1) {
            const reply = try self.receive(deadline, cancel);
            errdefer reply.deinit();
            const v = reply.value;
            if (v != .object) return error.McpInvalidResponse;
            const version = v.object.get("jsonrpc") orelse return error.McpInvalidResponse;
            if (version != .string or !std.mem.eql(u8, version.string, "2.0")) return error.McpInvalidResponse;
            if (v.object.get("method")) |m| {
                if (m != .string) return error.McpInvalidResponse;
                if (v.object.get("id")) |server_id| {
                    if (std.mem.eql(u8, m.string, "ping")) {
                        try self.send(.{ .jsonrpc = "2.0", .id = server_id, .result = struct {}{} }, deadline, cancel);
                    } else {
                        try self.send(.{ .jsonrpc = "2.0", .id = server_id, .@"error" = .{ .code = @as(i32, -32601), .message = "Client capability not supported" } }, deadline, cancel);
                    }
                }
                reply.deinit();
                continue;
            }
            const response_id = v.object.get("id") orelse return error.McpInvalidResponse;
            if (response_id != .integer or response_id.integer != id) return error.McpInvalidResponse;
            const has_error = v.object.get("error") != null;
            const has_result = v.object.get("result") != null;
            if (has_error == has_result) return error.McpInvalidResponse;
            return reply;
        }
        return error.McpTooManyMessages;
    }

    fn initialize(self: *Client) !void {
        try initializePeer(self);
    }

    fn notifyInitialized(self: *Client) !void {
        try self.send(.{ .jsonrpc = "2.0", .method = "notifications/initialized" }, time.milliTimestamp() + self.timeout_ms, null);
    }
};

fn nonblock(fd: std.posix.fd_t) !void {
    const flags = std.c.fcntl(fd, std.posix.F.GETFL, @as(c_int, 0));
    if (std.posix.errno(flags) != .SUCCESS) return error.McpIo;
    const bit: c_int = @bitCast(std.posix.O{ .NONBLOCK = true });
    if (std.posix.errno(std.c.fcntl(fd, std.posix.F.SETFL, flags | bit)) != .SUCCESS) return error.McpIo;
}

pub const Manager = struct {
    alloc: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    clients: std.ArrayList(*Peer) = .empty,
    entries: std.ArrayList(tools.Entry) = .empty,
    servers: std.ArrayList(ServerStatus) = .empty,

    const ServerStatus = struct {
        name: []const u8,
        transport: []const u8,
        enabled: bool,
        client: ?*Peer = null,
        failure: ?[]const u8 = null,
    };

    /// Pointer-stable lifetime: all entry metadata and dispatch contexts belong to this manager.
    pub fn create(alloc: std.mem.Allocator, raw: []const u8) !*Manager {
        const self = try alloc.create(Manager);
        self.* = .{ .alloc = alloc, .arena = std.heap.ArenaAllocator.init(alloc) };
        errdefer self.destroy();
        const a = self.arena.allocator();
        const parsed = try std.json.parseFromSlice(std.json.Value, a, raw, .{ .allocate = .alloc_always });
        try validate(parsed.value);
        var it = parsed.value.object.iterator();
        while (it.next()) |kv| {
            const server = try std.json.parseFromValue(Server, a, kv.value_ptr.*, .{});
            try self.servers.append(a, .{ .name = kv.key_ptr.*, .transport = if (server.value.url != null) "http" else "stdio", .enabled = server.value.enabled });
            const status = &self.servers.items[self.servers.items.len - 1];
            if (!server.value.enabled) continue;
            const client = try a.create(Peer);
            client.* = Peer.init(alloc, server.value) catch |err| {
                if (err == error.OutOfMemory) return err;
                status.failure = @errorName(err);
                continue;
            };
            self.clients.append(alloc, client) catch |err| {
                client.deinit();
                return err;
            };
            status.client = client;
            client.initialize() catch |err| {
                if (err == error.OutOfMemory) return err;
                status.failure = @errorName(err);
                client.stop();
                continue;
            };
            const before = self.entries.items.len;
            self.discover(kv.key_ptr.*, client) catch |err| {
                if (err == error.OutOfMemory) return err;
                self.entries.items.len = before;
                status.failure = @errorName(err);
                client.stop();
            };
        }
        return self;
    }

    pub fn destroy(self: *Manager) void {
        for (self.clients.items) |c| c.deinit();
        self.clients.deinit(self.alloc);
        self.entries.deinit(self.alloc);
        self.arena.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }

    fn discover(self: *Manager, server_name: []const u8, client: *Peer) !void {
        const a = self.arena.allocator();
        var cursor: ?[]const u8 = null;
        var seen: std.StringHashMap(void) = .init(a);
        var pages: usize = 0;
        while (pages < 32) : (pages += 1) {
            const reply = if (cursor) |c| try client.request("tools/list", .{ .cursor = c }, null) else try client.request("tools/list", struct {}{}, null);
            defer reply.deinit();
            const result = reply.value.object.get("result") orelse return error.McpRemoteError;
            if (result != .object) return error.McpInvalidResponse;
            const list = result.object.get("tools") orelse return error.McpInvalidResponse;
            if (list != .array) return error.McpInvalidResponse;
            for (list.array.items) |tool| {
                if (self.entries.items.len == max_tools) return error.McpTooManyTools;
                if (tool != .object) return error.McpInvalidResponse;
                const name = tool.object.get("name") orelse return error.McpInvalidResponse;
                if (name != .string or name.string.len == 0 or name.string.len > 256) return error.McpInvalidResponse;
                const schema = tool.object.get("inputSchema") orelse return error.McpInvalidResponse;
                if (schema != .object) return error.McpInvalidResponse;
                const desc = tool.object.get("description") orelse std.json.Value{ .string = "MCP tool" };
                if (desc != .string) return error.McpInvalidResponse;
                const ctx = try a.create(Binding);
                const public_name = try toolName(a, server_name, name.string);
                for (self.entries.items) |e| if (std.mem.eql(u8, e.name, public_name)) return error.McpDuplicateTool;
                ctx.* = .{ .client = client, .server_name = server_name, .remote_name = try a.dupe(u8, name.string), .public_name = public_name };
                try self.entries.append(self.alloc, .{
                    .name = public_name,
                    .kind = .mcp,
                    .spec = .{ .kind = .mcp, .desc = try a.dupe(u8, desc.string), .params = &.{}, .schema_json = try std.json.Stringify.valueAlloc(a, schema, .{}), .out = .{ .max_bytes = max_frame, .stream = false }, .timeout_ms = client.timeout_ms, .destructive = true },
                    .dispatch = &ctx.dispatch,
                });
            }
            const next = result.object.get("nextCursor") orelse return;
            if (next == .null) return;
            if (next != .string or next.string.len == 0 or seen.contains(next.string)) return error.McpInvalidCursor;
            cursor = try a.dupe(u8, next.string);
            try seen.put(cursor.?, {});
        }
        return error.McpTooManyPages;
    }
};

fn toolName(alloc: std.mem.Allocator, server: []const u8, remote: []const u8) ![]u8 {
    // Always hash the complete pair: separators in server/tool names cannot create aliases.
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(server);
    hash.update(&.{0});
    hash.update(remote);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    const hex = std.fmt.bytesToHex(digest[0..8].*, .lower);
    var readable: [16]u8 = undefined;
    const n = @min(remote.len, readable.len);
    for (remote[0..n], 0..) |c, i| readable[i] = if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') c else '_';
    return std.fmt.allocPrint(alloc, "mcp_{s}__{s}_{s}", .{ server[0..@min(server.len, 16)], readable[0..n], hex });
}

const Binding = struct {
    dispatch: tools.Dispatch = .{ .vt = &tools.Dispatch.Bind(Binding, run).vt },
    client: *Peer,
    server_name: []const u8,
    remote_name: []const u8,
    public_name: []const u8,

    fn run(self: *Binding, call: tools.Call, _: *tools.Sink) !tools.Result {
        if (call.args != .mcp) return error.KindMismatch;
        const parsed = try std.json.parseFromSlice(std.json.Value, self.client.alloc, call.args.mcp.arguments, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidArgs;
        const reply = try self.client.request("tools/call", .{ .name = self.remote_name, .arguments = parsed.value }, call.cancel);
        defer reply.deinit();
        const rpc_error = reply.value.object.get("error");
        const value = reply.value.object.get("result") orelse rpc_error.?;
        if (value != .object) return error.McpInvalidResponse;
        const failed = if (rpc_error != null) std.json.Value{ .bool = true } else value.object.get("isError") orelse std.json.Value{ .bool = false };
        if (failed != .bool) return error.McpInvalidResponse;
        const raw = try std.json.Stringify.valueAlloc(self.client.alloc, value, .{});
        errdefer self.client.alloc.free(raw);
        var result = try tools.shared.buildResult(self.client.alloc, call.id, call.at_ms, raw, max_frame, raw.len);
        if (failed.bool) result.final = .{ .failed = .{ .kind = .internal, .msg = "MCP tool returned isError" } };
        return result;
    }
};

test "MCP configuration rejects invalid executable environment and timeout" {
    const a = std.testing.allocator;
    const cases = [_][]const u8{ "[]", "{\"a\":{\"command\":\"\"}}", "{\"a\":{\"command\":\"true\",\"timeout_ms\":0}}", "{\"a\":{\"command\":\"true\",\"env\":{\"X\":3}}}" };
    for (cases) |raw| {
        const parsed = try std.json.parseFromSlice(std.json.Value, a, raw, .{});
        defer parsed.deinit();
        try std.testing.expectError(error.InvalidMcpConfig, validate(parsed.value));
    }
}

test "MCP disabled servers never execute" {
    const m = try Manager.create(std.testing.allocator, "{\"test\":{\"command\":\"/does-not-exist\",\"enabled\":false}}");
    defer m.destroy();
    try std.testing.expectEqual(@as(usize, 0), m.entries.items.len);
}

const fixture = @embedFile("../test/fixtures/mcp_server.py");

fn fixtureManager(mode: []const u8) !*Manager {
    const a = std.testing.allocator;
    const raw = try std.json.Stringify.valueAlloc(a, .{ .fixture = .{
        .command = "python3",
        .args = .{ "-u", "-c", fixture, mode },
        .env = .{ .PZ_MCP_FIXTURE = "configured" },
        .timeout_ms = @as(u32, 1000),
    } }, .{});
    defer a.free(raw);
    return Manager.create(a, raw);
}

const Noop = struct {
    sink: tools.Sink = .{ .vt = &tools.Sink.Bind(Noop, push).vt },
    fn push(_: *Noop, _: tools.Event) !void {}
};

test "MCP stdio handshake pagination schemas names and repeated calls" {
    const m = try fixtureManager("normal");
    defer m.destroy();
    try std.testing.expectEqual(@as(usize, 2), m.entries.items.len);
    const entry = m.entries.items[0];
    try std.testing.expect(std.mem.startsWith(u8, entry.name, "mcp_fixture__echo_tool_"));
    try std.testing.expect(entry.name.len <= 64);
    try std.testing.expect(std.mem.indexOf(u8, entry.spec.schema_json.?, "additionalProperties") != null);
    var noop: Noop = .{};
    for (0..2) |_| {
        const result = try tools.Registry.init(m.entries.items).run(entry.name, .{
            .id = "call",
            .kind = .mcp,
            .args = .{ .mcp = .{ .name = entry.name, .arguments = "{\"text\":\"hello\"}" } },
            .src = .model,
            .at_ms = 1,
        }, &noop.sink);
        defer tools.shared.deinitResult(std.testing.allocator, result);
        try std.testing.expect(result.final == .ok);
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result.out[0].chunk, .{});
        defer parsed.deinit();
        const structured = parsed.value.object.get("structuredContent").?;
        try std.testing.expectEqualStrings("echo.tool", structured.object.get("remote").?.string);
        try std.testing.expectEqualStrings("configured", structured.object.get("env").?.string);
    }
}

test "MCP preserves tool and JSON-RPC errors without losing the connection" {
    for ([_][]const u8{ "tool_error", "rpc" }) |mode| {
        const m = try fixtureManager(mode);
        defer m.destroy();
        var noop: Noop = .{};
        for (0..2) |_| {
            const result = try m.entries.items[0].dispatch.run(.{ .id = "error", .kind = .mcp, .args = .{ .mcp = .{ .arguments = "{\"text\":\"diagnostic\"}" } }, .src = .model, .at_ms = 0 }, &noop.sink);
            defer tools.shared.deinitResult(std.testing.allocator, result);
            try std.testing.expect(result.final == .failed);
            try std.testing.expect(std.mem.indexOf(u8, result.out[0].chunk, if (std.mem.eql(u8, mode, "rpc")) "fixture remote error" else "diagnostic") != null);
        }
    }
}

test "MCP malformed responses wrong IDs oversized frames and repeated cursors fail closed" {
    const cases = [_]struct { mode: []const u8, failure: []const u8 }{
        .{ .mode = "wrongid", .failure = "McpInvalidResponse" },
        .{ .mode = "malformed", .failure = "SyntaxError" },
        .{ .mode = "large", .failure = "McpFrameTooLarge" },
        .{ .mode = "cursor", .failure = "McpInvalidCursor" },
    };
    for (cases) |case| {
        const m = try fixtureManager(case.mode);
        defer m.destroy();
        try std.testing.expectEqual(@as(usize, 0), m.entries.items.len);
        try std.testing.expectEqualStrings(case.failure, m.servers.items[0].failure.?);
    }
}

test "MCP request deadline terminates a stalled child" {
    var client = try Client.init(std.testing.allocator, .{ .command = "python3", .args = &.{ "-u", "-c", fixture, "hang" }, .timeout_ms = 100 });
    defer client.deinit();
    try std.testing.expectError(error.McpTimeout, client.initialize());
    try std.testing.expect(client.closed);
}

test "MCP cancellation invalidates the stream" {
    const m = try fixtureManager("callhang");
    defer m.destroy();
    const Cancel = struct {
        cancel_src: tools.CancelSrc = .{ .vt = &tools.CancelSrc.Bind(@This(), canceled).vt },
        fn canceled(_: *@This()) bool {
            return true;
        }
    };
    var cancel: Cancel = .{};
    var noop: Noop = .{};
    const call: tools.Call = .{ .id = "cancel", .kind = .mcp, .args = .{ .mcp = .{ .arguments = "{\"text\":\"test\"}" } }, .src = .model, .at_ms = 0, .cancel = &cancel.cancel_src };
    try std.testing.expectError(error.McpCancelled, m.entries.items[0].dispatch.run(call, &noop.sink));
    try std.testing.expectError(error.McpClosed, m.entries.items[0].dispatch.run(call, &noop.sink));
}

test "MCP names separate ambiguous pairs and support long non-ASCII remote names" {
    const a = std.testing.allocator;
    const first = try toolName(a, "a__b", "c");
    defer a.free(first);
    const second = try toolName(a, "a", "b__c");
    defer a.free(second);
    try std.testing.expect(!std.mem.eql(u8, first, second));
    const long = try toolName(a, "server", "remote.tool/имя-very-long-name-which-would-not-fit-into-a-provider-name");
    defer a.free(long);
    try std.testing.expect(long.len <= 64);
    try std.testing.expect(identifier(long));
}

fn initializePeer(peer: anytype) !void {
    const reply = try peer.request("initialize", .{ .protocolVersion = "2024-11-05", .capabilities = struct {}{}, .clientInfo = .{ .name = "pz", .version = "1.0" } }, null);
    defer reply.deinit();
    const result = reply.value.object.get("result") orelse return error.McpRemoteError;
    if (result != .object) return error.McpInvalidResponse;
    const version = result.object.get("protocolVersion") orelse return error.McpInvalidResponse;
    if (version != .string) return error.McpInvalidResponse;
    const supported = [_][]const u8{ "2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25" };
    for (supported) |v| {
        if (!std.mem.eql(u8, v, version.string)) continue;
        if (@TypeOf(peer) == *Http) peer.protocol_version = v;
        try peer.notifyInitialized();
        return;
    }
    return error.McpUnsupportedVersion;
}

const Peer = struct {
    alloc: std.mem.Allocator,
    timeout_ms: u32,
    transport: union(enum) { stdio: Client, http: Http },

    fn init(alloc: std.mem.Allocator, server: Server) !Peer {
        return .{ .alloc = alloc, .timeout_ms = server.timeout_ms, .transport = if (server.url) |url|
            .{ .http = .{ .alloc = alloc, .url = url, .headers = server.headers, .timeout_ms = server.timeout_ms } }
        else
            .{ .stdio = try Client.init(alloc, server) } };
    }
    fn deinit(self: *Peer) void {
        switch (self.transport) {
            .stdio => |*c| c.deinit(),
            .http => |*h| h.deinit(),
        }
    }
    fn initialize(self: *Peer) !void {
        switch (self.transport) {
            .stdio => |*c| try c.initialize(),
            .http => |*h| try initializePeer(h),
        }
    }
    fn request(self: *Peer, method: []const u8, params: anytype, cancel: ?*tools.CancelSrc) !std.json.Parsed(std.json.Value) {
        return switch (self.transport) {
            .stdio => |*c| c.request(method, params, cancel),
            .http => |*h| h.request(method, params, cancel),
        };
    }
    fn stop(self: *Peer) void {
        switch (self.transport) {
            .stdio => |*c| c.close(),
            .http => {},
        }
    }
    fn connected(self: *const Peer) bool {
        return switch (self.transport) {
            .stdio => |c| !c.closed,
            .http => true,
        };
    }
};

/// Streamable HTTP POST transport. curl supplies TLS and HTTP decoding, as in the web tool.
/// No redirects, implicit curl config, or proxy credentials are allowed.
const Http = struct {
    alloc: std.mem.Allocator,
    url: []const u8,
    headers: ?std.json.Value,
    timeout_ms: u32,
    session: ?[]u8 = null,
    protocol_version: []const u8 = "2024-11-05",
    next_id: i64 = 0,

    fn deinit(self: *Http) void {
        if (self.session) |s| self.alloc.free(s);
    }
    fn notifyInitialized(self: *Http) !void {
        const response = try self.exchange(.{ .jsonrpc = "2.0", .method = "notifications/initialized" }, null, null);
        if (response) |r| r.deinit();
    }
    fn request(self: *Http, method: []const u8, params: anytype, cancel: ?*tools.CancelSrc) !std.json.Parsed(std.json.Value) {
        self.next_id += 1;
        return (try self.exchange(.{ .jsonrpc = "2.0", .id = self.next_id, .method = method, .params = params }, self.next_id, cancel)) orelse error.McpInvalidResponse;
    }

    fn exchange(self: *Http, message: anytype, id: ?i64, cancel: ?*tools.CancelSrc) !?std.json.Parsed(std.json.Value) {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(a, &.{ "--disable", "--silent", "--show-error", "--no-buffer", "--include", "--noproxy", "*", "--proto", "=http,https", "--request", "POST", "--header", "Content-Type: application/json", "--header", "Accept: application/json, text/event-stream", "--header", "Expect:", "--data-binary", "@-", "--max-time", try std.fmt.allocPrint(a, "{d}.{d:0>3}", .{ self.timeout_ms / 1000, self.timeout_ms % 1000 }), "--header", try std.fmt.allocPrint(a, "MCP-Protocol-Version: {s}", .{self.protocol_version}) });
        if (self.session) |s| try args.appendSlice(a, &.{ "--header", try std.fmt.allocPrint(a, "Mcp-Session-Id: {s}", .{s}) });
        if (self.headers) |headers| {
            var it = headers.object.iterator();
            while (it.next()) |h| try args.appendSlice(a, &.{ "--header", try std.fmt.allocPrint(a, "{s}: {s}", .{ h.key_ptr.*, h.value_ptr.string }) });
        }
        try args.appendSlice(a, &.{ "--url", self.url });
        var runner = try Client.init(self.alloc, .{ .command = "curl", .args = args.items, .timeout_ms = self.timeout_ms });
        defer runner.deinit();
        const deadline = time.milliTimestamp() + self.timeout_ms;
        try runner.send(message, deadline, cancel);
        runner.child.stdin.?.close(sys.io);
        runner.child.stdin = null;
        var raw: std.ArrayList(u8) = .empty;
        defer raw.deinit(self.alloc);
        var header_done = false;
        var sse = false;
        var eof = false;
        while (true) {
            if (!header_done) {
                if (std.mem.indexOf(u8, raw.items, "\r\n\r\n")) |end| {
                    var lines = std.mem.splitSequence(u8, raw.items[0..end], "\r\n");
                    const status_line = lines.next() orelse return error.McpInvalidHttp;
                    var words = std.mem.tokenizeScalar(u8, status_line, ' ');
                    const protocol = words.next() orelse return error.McpInvalidHttp;
                    if (!std.mem.startsWith(u8, protocol, "HTTP/")) return error.McpInvalidHttp;
                    const status = std.fmt.parseInt(u16, words.next() orelse return error.McpInvalidHttp, 10) catch return error.McpInvalidHttp;
                    if (status >= 100 and status < 200) {
                        discard(&raw, end + 4);
                        continue;
                    }
                    if (status == 401 or status == 403) return error.McpHttpUnauthorized;
                    if (status < 200 or status >= 300) return error.McpHttpStatus;
                    var content_type: ?[]const u8 = null;
                    while (lines.next()) |line| {
                        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.McpInvalidHttp;
                        const name = line[0..colon];
                        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
                        if (std.ascii.eqlIgnoreCase(name, "Content-Type")) content_type = value;
                        if (std.ascii.eqlIgnoreCase(name, "Mcp-Session-Id")) {
                            if (value.len == 0 or value.len > 512) return error.McpInvalidHttp;
                            for (value) |c| if (c < 0x21 or c > 0x7e) return error.McpInvalidHttp;
                            const session = try self.alloc.dupe(u8, value);
                            if (self.session) |old| self.alloc.free(old);
                            self.session = session;
                        }
                    }
                    if (id == null) return null;
                    const ct = content_type orelse return error.McpInvalidHttp;
                    sse = std.ascii.startsWithIgnoreCase(ct, "text/event-stream");
                    if (!sse and !std.ascii.startsWithIgnoreCase(ct, "application/json")) return error.McpInvalidHttp;
                    discard(&raw, end + 4);
                    header_done = true;
                } else if (raw.items.len > 65536 or eof) return error.McpInvalidHttp;
            }
            if (header_done and sse) {
                while (eventEnd(raw.items)) |end| {
                    var data: std.ArrayList(u8) = .empty;
                    defer data.deinit(self.alloc);
                    var lines = std.mem.splitScalar(u8, raw.items[0..end.at], '\n');
                    while (lines.next()) |raw_line| {
                        const line = std.mem.trimEnd(u8, raw_line, "\r");
                        if (!std.mem.startsWith(u8, line, "data:")) continue;
                        var field = line[5..];
                        if (std.mem.startsWith(u8, field, " ")) field = field[1..];
                        if (data.items.len != 0) try data.append(self.alloc, '\n');
                        try data.appendSlice(self.alloc, field);
                    }
                    discard(&raw, end.at + end.len);
                    if (data.items.len != 0) {
                        if (try self.parseResponse(data.items, id.?)) |r| return r;
                    }
                }
            }
            if (eof) {
                if (!header_done or sse) return error.McpClosed;
                return (try self.parseResponse(raw.items, id.?)) orelse error.McpInvalidResponse;
            }
            try runner.ready(runner.child.stdout.?.handle, std.posix.POLL.IN, deadline, cancel);
            var buf: [4096]u8 = undefined;
            const n = std.posix.read(runner.child.stdout.?.handle, &buf) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
            if (n == 0) {
                eof = true;
                continue;
            }
            if (raw.items.len + n > max_frame + 65536) return error.McpFrameTooLarge;
            try raw.appendSlice(self.alloc, buf[0..n]);
        }
    }

    fn parseResponse(self: *Http, raw: []const u8, id: i64) !?std.json.Parsed(std.json.Value) {
        if (raw.len > max_frame) return error.McpFrameTooLarge;
        const parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, raw, .{ .allocate = .alloc_always });
        errdefer parsed.deinit();
        const v = parsed.value;
        if (v != .object) return error.McpInvalidResponse;
        const version = v.object.get("jsonrpc") orelse return error.McpInvalidResponse;
        if (version != .string or !std.mem.eql(u8, version.string, "2.0")) return error.McpInvalidResponse;
        if (v.object.get("method")) |method| {
            if (method != .string or v.object.get("id") != null) return error.McpUnsupportedRequest;
            parsed.deinit();
            return null; // Notifications interleaved with an SSE response.
        }
        const rid = v.object.get("id") orelse return error.McpInvalidResponse;
        if (rid != .integer or rid.integer != id or (v.object.get("result") == null) == (v.object.get("error") == null)) return error.McpInvalidResponse;
        return parsed;
    }
};

fn discard(buffer: *std.ArrayList(u8), n: usize) void {
    const remaining = buffer.items.len - n;
    std.mem.copyForwards(u8, buffer.items[0..remaining], buffer.items[n..]);
    buffer.items.len = remaining;
}
fn eventEnd(raw: []const u8) ?struct { at: usize, len: usize } {
    const lf = std.mem.indexOf(u8, raw, "\n\n");
    const crlf = std.mem.indexOf(u8, raw, "\r\n\r\n");
    if (lf) |at| if (crlf == null or at < crlf.?) {
        return .{ .at = at, .len = 2 };
    };
    if (crlf) |at| return .{ .at = at, .len = 4 };
    return null;
}

/// Safe public inventory: never expose executable arguments, environment variables or HTTP headers.
pub fn reportAlloc(alloc: std.mem.Allocator, manager: ?*const Manager) ![]u8 {
    const ServerView = struct { name: []const u8, transport: []const u8, status: []const u8, @"error": ?[]const u8, tool_count: usize };
    const ToolView = struct { server: []const u8, name: []const u8, remote_name: []const u8, description: []const u8 };
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const servers = try a.alloc(ServerView, if (manager) |m| m.servers.items.len else 0);
    const inventory = try a.alloc(ToolView, if (manager) |m| m.entries.items.len else 0);
    if (manager) |m| {
        for (m.entries.items, 0..) |entry, i| {
            const binding: *Binding = @alignCast(@fieldParentPtr("dispatch", entry.dispatch));
            inventory[i] = .{ .server = binding.server_name, .name = entry.name, .remote_name = binding.remote_name, .description = entry.spec.desc };
        }
        for (m.servers.items, 0..) |s, i| {
            var count: usize = 0;
            for (inventory) |tool| if (std.mem.eql(u8, tool.server, s.name)) {
                count += 1;
            };
            servers[i] = .{ .name = s.name, .transport = s.transport, .status = if (!s.enabled) "disabled" else if (s.failure != null) "failed" else if (s.client != null and s.client.?.connected()) "connected" else "disconnected", .@"error" = s.failure, .tool_count = count };
        }
    }
    return std.json.Stringify.valueAlloc(alloc, .{ .servers = servers, .tools = inventory }, .{ .whitespace = .indent_2 });
}

pub fn summaryAlloc(alloc: std.mem.Allocator, manager: ?*const Manager) !?[]u8 {
    const m = manager orelse return null;
    if (m.servers.items.len == 0) return null;
    var out = std.Io.Writer.Allocating.init(alloc);
    defer out.deinit();
    for (m.servers.items, 0..) |s, i| {
        if (i != 0) try out.writer.writeByte('\n');
        if (!s.enabled) {
            try out.writer.print("{s} (disabled)", .{s.name});
        } else if (s.failure) |failure| {
            try out.writer.print("{s} (failed: {s})", .{ s.name, failure });
        } else {
            var count: usize = 0;
            for (m.entries.items) |e| {
                const binding: *Binding = @alignCast(@fieldParentPtr("dispatch", e.dispatch));
                if (std.mem.eql(u8, binding.server_name, s.name)) count += 1;
            }
            try out.writer.print("{s} ({s}, {d} tools)", .{ s.name, if (s.client != null and s.client.?.connected()) @as([]const u8, "connected") else "disconnected", count });
        }
    }
    return try alloc.dupe(u8, out.written());
}

const HttpFixture = struct {
    runner: Client,
    url: []u8,
    fn start(mode: []const u8) !HttpFixture {
        const a = std.testing.allocator;
        var runner = try Client.init(a, .{ .command = "python3", .args = &.{ "-u", "-c", @embedFile("../test/fixtures/mcp_http_server.py"), mode } });
        errdefer runner.deinit();
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(a);
        const deadline = time.milliTimestamp() + 3000;
        while (line.items.len < 256) {
            try runner.ready(runner.child.stdout.?.handle, std.posix.POLL.IN, deadline, null);
            var byte: [1]u8 = undefined;
            const n = std.posix.read(runner.child.stdout.?.handle, &byte) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
            if (n == 0) return error.McpClosed;
            if (byte[0] == '\n') return .{ .runner = runner, .url = try a.dupe(u8, line.items) };
            try line.append(a, byte[0]);
        }
        return error.McpInvalidHttp;
    }
    fn deinit(self: *HttpFixture) void {
        self.runner.deinit();
        std.testing.allocator.free(self.url);
    }
    fn manager(self: *const HttpFixture) !*Manager {
        const a = std.testing.allocator;
        const raw = try std.json.Stringify.valueAlloc(a, .{ .remote = .{ .url = self.url, .headers = .{ .Authorization = "Bearer fixture-secret" }, .timeout_ms = @as(u32, 2000) } }, .{});
        defer a.free(raw);
        return Manager.create(a, raw);
    }
};

test "MCP Streamable HTTP JSON and SSE sessions custom headers and tool calls" {
    for ([_][]const u8{ "json", "sse" }) |mode| {
        var fixture_http = try HttpFixture.start(mode);
        defer fixture_http.deinit();
        const m = try fixture_http.manager();
        defer m.destroy();
        try std.testing.expect(m.servers.items[0].failure == null);
        try std.testing.expectEqual(@as(usize, 1), m.entries.items.len);
        var noop: Noop = .{};
        const result = try m.entries.items[0].dispatch.run(.{ .id = "http", .kind = .mcp, .args = .{ .mcp = .{ .arguments = "{\"text\":\"http works\"}" } }, .src = .model, .at_ms = 0 }, &noop.sink);
        defer tools.shared.deinitResult(std.testing.allocator, result);
        try std.testing.expect(result.final == .ok);
        try std.testing.expect(std.mem.indexOf(u8, result.out[0].chunk, "http works") != null);
        const report = try reportAlloc(std.testing.allocator, m);
        defer std.testing.allocator.free(report);
        try std.testing.expect(std.mem.indexOf(u8, report, "fixture-secret") == null);
        try std.testing.expect(std.mem.indexOf(u8, report, "connected") != null);
    }
}

test "MCP HTTP authentication errors and redirects are reported without following redirects" {
    for ([_][]const u8{ "unauthorized", "redirect" }) |mode| {
        var fixture_http = try HttpFixture.start(mode);
        defer fixture_http.deinit();
        const m = try fixture_http.manager();
        defer m.destroy();
        try std.testing.expectEqualStrings(if (std.mem.eql(u8, mode, "unauthorized")) "McpHttpUnauthorized" else "McpHttpStatus", m.servers.items[0].failure.?);
        try std.testing.expectEqual(@as(usize, 0), m.entries.items.len);
    }
}

test "MCP inventory and startup summary include disabled and failed servers without credentials" {
    const a = std.testing.allocator;
    const m = try Manager.create(a, "{\"disabled\":{\"command\":\"unused-secret\",\"enabled\":false},\"broken\":{\"command\":\"/nonexistent-mcp-program\",\"env\":{\"KEY\":\"secret-value\"}}}");
    defer m.destroy();
    const report = try reportAlloc(a, m);
    defer a.free(report);
    const summary = (try summaryAlloc(a, m)).?;
    defer a.free(summary);
    try std.testing.expect(std.mem.indexOf(u8, summary, "disabled (disabled)") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "broken (failed:") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "secret-value") == null);
    try std.testing.expect(std.mem.indexOf(u8, report, "unused-secret") == null);
}
