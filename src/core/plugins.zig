//! Explicitly configured in-process JavaScript plugins with bounded microtasks.
const std = @import("std");
const sys = @import("pz_io");
const tools = @import("tools.zig");
const path_guard = @import("tools/path_guard.zig");
// Keep these declarations in sync with plugins_bridge.h. Zig 0.17 removed @cImport.
const c = struct {
    const pz_js = opaque {};
    extern fn pz_js_create() ?*pz_js;
    extern fn pz_js_destroy(p: *pz_js) void;
    extern fn pz_js_eval(p: *pz_js, source: [*:0]const u8, len: usize, filename: [*:0]const u8) c_int;
    extern fn pz_js_load(p: *pz_js, source: [*:0]const u8, len: usize, filename: [*:0]const u8) c_int;
    extern fn pz_js_call(p: *pz_js, request: [*]const u8, len: usize) ?[*:0]u8;
    extern fn pz_js_error(p: *pz_js) [*:0]const u8;
    extern fn pz_js_free_string(s: [*:0]u8) void;
};
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
    has_footer: bool = false,
    has_lifecycle: bool = false,
    has_tool_renderers: bool = false,

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
            const filename = try a.dupeSentinel(u8, item.string, 0);
            // Modules isolate lexical scope and optionally export a native pz factory.
            try self.load(source, filename);
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
                .origin = .plugin,
                .kind = .mcp,
                .spec = .{ .kind = .mcp, .desc = item.object.get("description").?.string, .params = &.{}, .schema_json = try std.json.Stringify.valueAlloc(a, item.object.get("parameters").?, .{}), .out = .{ .max_bytes = max_bytes, .stream = false }, .timeout_ms = 1000, .destructive = true },
                .dispatch = &binding.dispatch,
            });
        }
        const inventory = try self.report();
        defer alloc.free(inventory);
        const description = try std.json.parseFromSlice(struct { events: []const []const u8, renderers: []const []const u8 = &.{} }, alloc, inventory, .{ .ignore_unknown_fields = true });
        defer description.deinit();
        self.has_tool_renderers = description.value.renderers.len > 0;
        for (description.value.events) |event_name| {
            if (std.mem.eql(u8, event_name, "footer_render")) self.has_footer = true;
            for ([_][]const u8{ "agent_start", "agent_end", "turn_start", "turn_end", "tool_execution_start", "tool_execution_end" }) |lifecycle| {
                if (std.mem.eql(u8, event_name, lifecycle)) self.has_lifecycle = true;
            }
        }
        return self;
    }

    pub fn setContext(self: *Manager, value: anytype) !void {
        const reply = try self.request(self.alloc, .{ .op = "event", .name = "__host_context", .payload = .{}, .context = value });
        self.alloc.free(reply);
    }

    pub fn renderTool(self: *Manager, alloc: std.mem.Allocator, payload: anytype) ![]u8 {
        return self.request(alloc, .{ .op = "event", .name = "__render_tool", .payload = payload });
    }

    pub fn footer(self: *Manager, alloc: std.mem.Allocator, payload: anytype) ![]u8 {
        return self.request(alloc, .{ .op = "event", .name = "footer_render", .payload = payload });
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
        const terminated = try self.alloc.dupeSentinel(u8, source, 0);
        defer self.alloc.free(terminated);
        if (c.pz_js_eval(self.runtime, terminated.ptr, source.len, filename.ptr) != 0) {
            std.log.warn("Plugin {s}: {s}", .{ filename, self.diagnostic() });
            return error.PluginJavaScript;
        }
    }

    fn load(self: *Manager, source: []const u8, filename: [:0]const u8) !void {
        const terminated = try self.alloc.dupeSentinel(u8, source, 0);
        defer self.alloc.free(terminated);
        if (c.pz_js_load(self.runtime, terminated.ptr, source.len, filename.ptr) != 0) {
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
        const raw = try self.manager.request(alloc, .{ .op = "tool", .name = self.name, .toolCallId = call.id, .args = parsed.value });
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

test "native module factory receives pz and awaits initialization" {
    const a = std.testing.allocator;
    const runtime = c.pz_js_create() orelse return error.OutOfMemory;
    const manager = try a.create(Manager);
    manager.* = .{ .alloc = a, .arena = std.heap.ArenaAllocator.init(a), .runtime = runtime };
    defer manager.destroy();
    try manager.eval(@embedFile("plugins_bootstrap.js"), "test:bootstrap");
    try manager.load(
        \\export default async function(api) {
        \\  await Promise.resolve();
        \\  if (api !== pz || typeof globalThis.pi !== 'undefined') throw Error('Wrong native API');
        \\  api.registerCommand('module_echo', {handler:args => 'echo:' + args});
        \\  api.registerTool({name:'module_tool',description:'Native tool',parameters:{type:'object'},execute:(args,ctx) => ctx.cwd + ':' + args.value});
        \\}
    , "test:native-module.mjs");
    try manager.setContext(.{ .cwd = "/project" });
    const command = (try manager.command("/module_echo two words")).?;
    defer a.free(command);
    try std.testing.expectEqualStrings("echo:two words", command);
    const tool = try manager.request(a, .{ .op = "tool", .name = "module_tool", .args = .{ .value = "value" } });
    defer a.free(tool);
    try std.testing.expectEqualStrings("{\"content\":[{\"type\":\"text\",\"text\":\"/project:value\"}]}", tool);
}

test "native module load rejects invalid factories imports and unsettled promises" {
    const a = std.testing.allocator;
    const cases = [_][]const u8{
        "export default 42;",
        "import unsupported from 'unsupported-native-test'; export default function(pz) {}",
        "export default async function(pz) { throw Error('factory rejected'); }",
        "export default function(pz) { return new Promise(() => {}); }",
    };
    for (cases) |source| {
        const manager = try Manager.create(a, "[]");
        defer manager.destroy();
        try std.testing.expectError(error.PluginJavaScript, manager.load(source, "test:invalid-module.mjs"));
        try std.testing.expect(manager.diagnostic().len != 0);
    }
}
