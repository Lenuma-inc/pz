//! Explicitly configured, synchronous in-process JavaScript plugins.
const std = @import("std");
const sys = @import("pz_io");
const tools = @import("tools.zig");
const path_guard = @import("tools/path_guard.zig");
const c = @cImport({
    @cInclude("plugins_bridge.h");
});
pub const max_tools = 64;
const max_bytes = 1024 * 1024;

pub fn validate(value: std.json.Value) !void {
    if (value != .array or value.array.items.len > 32) return error.InvalidPluginConfig;
    for (value.array.items) |item| {
        if (item != .string or item.string.len == 0 or item.string.len > 4096 or std.mem.indexOfScalar(u8, item.string, 0) != null) return error.InvalidPluginConfig;
    }
}

pub const Manager = struct {
    alloc: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    runtime: *c.pz_js,
    mutex: std.Io.Mutex = .init,
    entries: std.ArrayList(tools.Entry) = .empty,

    pub fn create(alloc: std.mem.Allocator, raw: []const u8) !*Manager {
        if (raw.len > max_bytes) return error.InvalidPluginConfig;
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, raw, .{});
        defer parsed.deinit();
        try validate(parsed.value);
        const runtime = c.pz_js_create() orelse return error.OutOfMemory;
        const self = alloc.create(Manager) catch |err| {
            c.pz_js_destroy(runtime);
            return err;
        };
        self.* = .{ .alloc = alloc, .arena = std.heap.ArenaAllocator.init(alloc), .runtime = runtime };
        errdefer self.destroy();
        const a = self.arena.allocator();
        try self.eval(@embedFile("plugins_bootstrap.js"), "pz:bootstrap");
        for (parsed.value.array.items) |item| {
            var file = try path_guard.openFile(item.string, .{ .mode = .read_only });
            defer file.close(sys.io);
            var buf: [4096]u8 = undefined;
            var reader = file.readerStreaming(sys.io, &buf);
            const source = try reader.interface.allocRemaining(alloc, .limited(max_bytes));
            defer alloc.free(source);
            const filename = try a.dupeZ(u8, item.string);
            // Separate lexical scope for each script; registration closures retain state.
            const isolated = try std.fmt.allocPrint(alloc, "(function(){{\"use strict\";\n{s}\n}})();", .{source});
            defer alloc.free(isolated);
            try self.eval(isolated, filename);
        }
        const list = try self.request(alloc, .{ .op = "list" });
        defer alloc.free(list);
        const metadata = try std.json.parseFromSlice(std.json.Value, a, list, .{ .allocate = .alloc_always });
        if (metadata.value != .array or metadata.value.array.items.len > max_tools) return error.InvalidPluginTools;
        for (metadata.value.array.items) |item| {
            if (item != .object) return error.InvalidPluginTools;
            const n = item.object.get("name") orelse return error.InvalidPluginTools;
            const d = item.object.get("description") orelse return error.InvalidPluginTools;
            const p = item.object.get("parameters") orelse return error.InvalidPluginTools;
            if (n != .string or d != .string or p != .object or n.string.len == 0 or n.string.len > 128) return error.InvalidPluginTools;
            const name = n.string;
            // Reserved kinds include every builtin, even when currently masked off.
            if (std.meta.stringToEnum(tools.Kind, name) != null) return error.PluginBuiltinCollision;
            for (self.entries.items) |entry| if (std.mem.eql(u8, entry.name, name)) return error.DuplicatePluginTool;
            const binding = try a.create(Binding);
            binding.* = .{ .manager = self, .name = name };
            try self.entries.append(alloc, .{
                .name = name,
                .kind = .mcp,
                .spec = .{ .kind = .mcp, .desc = item.object.get("description").?.string, .params = &.{}, .schema_json = try std.json.Stringify.valueAlloc(a, item.object.get("parameters").?, .{}), .out = .{ .max_bytes = max_bytes, .stream = false }, .timeout_ms = 1000, .destructive = true },
                .dispatch = &binding.dispatch,
            });
        }
        return self;
    }

    pub fn destroy(self: *Manager) void {
        c.pz_js_destroy(self.runtime);
        self.entries.deinit(self.alloc);
        self.arena.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }

    pub fn diagnostic(self: *Manager) []const u8 {
        return std.mem.span(c.pz_js_error(self.runtime));
    }

    fn eval(self: *Manager, source: []const u8, filename: [:0]const u8) !void {
        // QuickJS requires a trailing NUL even though the source length is explicit.
        const terminated = try self.alloc.dupeZ(u8, source);
        defer self.alloc.free(terminated);
        if (c.pz_js_eval(self.runtime, terminated.ptr, source.len, filename.ptr) != 0) {
            std.log.warn("Plugin {s}: {s}", .{ filename, self.diagnostic() });
            return error.PluginJavaScript;
        }
    }

    fn request(self: *Manager, alloc: std.mem.Allocator, value: anytype) ![]u8 {
        const raw = try std.json.Stringify.valueAlloc(alloc, value, .{});
        defer alloc.free(raw);
        if (raw.len > max_bytes) return error.PluginInputTooLarge;
        self.mutex.lockUncancelable(sys.io);
        defer self.mutex.unlock(sys.io);
        const result = c.pz_js_call(self.runtime, raw.ptr, raw.len) orelse {
            std.log.warn("Plugin callback: {s}", .{self.diagnostic()});
            return error.PluginJavaScript;
        };
        defer c.pz_js_free_string(result);
        return alloc.dupe(u8, std.mem.span(result));
    }

    pub fn report(self: *Manager) ![]u8 {
        return self.request(self.alloc, .{ .op = "describe" });
    }

    pub fn command(self: *Manager, line: []const u8) !?[]u8 {
        if (line.len < 2 or line[0] != '/') return null;
        const end = std.mem.indexOfAny(u8, line, " \t\r\n") orelse line.len;
        const reply = try self.request(self.alloc, .{ .op = "command", .name = line[1..end], .args = std.mem.trim(u8, line[end..], " \t\r\n") });
        defer self.alloc.free(reply);
        const parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, reply, .{});
        defer parsed.deinit();
        if (parsed.value == .null) return null;
        if (parsed.value != .string) return error.InvalidPluginCommandResult;
        return try self.alloc.dupe(u8, parsed.value.string);
    }

    pub fn event(self: *Manager, alloc: std.mem.Allocator, name: []const u8, payload: []const u8) ![]u8 {
        if (payload.len > max_bytes) return error.PluginInputTooLarge;
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
        defer parsed.deinit();
        return self.request(alloc, .{ .op = "event", .name = name, .payload = parsed.value });
    }
};

const Binding = struct {
    dispatch: tools.Dispatch = .{ .vt = &tools.Dispatch.Bind(Binding, run).vt },
    manager: *Manager,
    name: []const u8,
    fn run(self: *Binding, call: tools.Call, _: *tools.Sink) !tools.Result {
        if (call.args != .mcp) return error.KindMismatch;
        if (call.args.mcp.arguments.len > max_bytes) return error.PluginInputTooLarge;
        const alloc = self.manager.alloc;
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, call.args.mcp.arguments, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidArgs;
        const raw = try self.manager.request(alloc, .{ .op = "tool", .name = self.name, .args = parsed.value });
        errdefer alloc.free(raw);
        return tools.shared.buildResult(alloc, call.id, call.at_ms, raw, max_bytes, raw.len);
    }
};

test "plugin configuration bounds and explicit paths" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "{}", "[1]", "[\"\"]", "[\"a\\u0000.js\"]" }) |raw| {
        const parsed = try std.json.parseFromSlice(std.json.Value, a, raw, .{});
        defer parsed.deinit();
        try std.testing.expectError(error.InvalidPluginConfig, validate(parsed.value));
    }
    const parsed = try std.json.parseFromSlice(std.json.Value, a, "[\"./plugin.js\"]", .{});
    defer parsed.deinit();
    try validate(parsed.value);
}

test "native plugin empty manager command and event contracts" {
    const a = std.testing.allocator;
    const manager = try Manager.create(a, "[]");
    defer manager.destroy();
    try std.testing.expectEqual(@as(usize, 0), manager.entries.items.len);
    try std.testing.expectEqual(@as(?[]u8, null), try manager.command("/missing args"));
    const reply = try manager.event(a, "session_start", "{}");
    defer a.free(reply);
    try std.testing.expectEqualStrings("{}", reply);
}

test "native plugin bootstrap synchronous callbacks and Promise rejection" {
    const a = std.testing.allocator;
    const runtime = c.pz_js_create() orelse return error.OutOfMemory;
    const manager = try a.create(Manager);
    manager.* = .{ .alloc = a, .arena = std.heap.ArenaAllocator.init(a), .runtime = runtime };
    defer manager.destroy();
    try manager.eval(@embedFile("plugins_bootstrap.js"), "test:bootstrap");
    try manager.eval(
        \\pz.registerCommand('echo', {handler:(args)=>args});
        \\pz.registerCommand('async', {handler:()=>Promise.resolve('no')});
        \\pz.on('before_request', ()=>({systemPromptAppend:'extra'}));
        \\pz.on('tool_call', ()=>({block:true,reason:'denied'}));
        \\pz.registerTool({name:'hello',description:'Hello',parameters:{type:'object'},execute:()=> 'world'});
    , "test:plugin");
    const command = (try manager.command("/echo two words")).?;
    defer a.free(command);
    try std.testing.expectEqualStrings("two words", command);
    const event = try manager.event(a, "before_request", "{}");
    defer a.free(event);
    try std.testing.expectEqualStrings("{\"systemPromptAppend\":\"extra\"}", event);
    const tool = try manager.request(a, .{ .op = "tool", .name = "hello", .args = .{} });
    defer a.free(tool);
    try std.testing.expectEqualStrings("{\"content\":[{\"type\":\"text\",\"text\":\"world\"}]}", tool);
    try std.testing.expectError(error.PluginJavaScript, manager.command("/async"));
    try std.testing.expect(std.mem.indexOf(u8, manager.diagnostic(), "Promise") != null);
}
