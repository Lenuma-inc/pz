//! Named OpenAI Responses-compatible endpoints and their live model catalogs.
const std = @import("std");
const sys = @import("pz_io");
const auth = @import("auth.zig");
const flow = @import("oauth_flow.zig");
const openai = @import("openai.zig");

pub const Entry = struct {
    name: []const u8,
    base_url: []const u8,
    api_key: []const u8,
};

pub const Registry = struct {
    arena: std.heap.ArenaAllocator,
    entries: []const Entry,

    pub fn deinit(self: *Registry) void {
        self.arena.deinit();
    }

    pub fn find(self: *const Registry, name: []const u8) ?Entry {
        for (self.entries) |entry| if (std.mem.eql(u8, name, entry.name)) return entry;
        return null;
    }
};

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or std.mem.eql(u8, name, "openai") or std.mem.eql(u8, name, "openrouter") or std.mem.eql(u8, name, "default")) return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    return true;
}

/// Accept a host root or a complete API base path; never rewrite non-root paths.
pub fn normalizeBaseUrl(alloc: std.mem.Allocator, url: []const u8) ![]u8 {
    const trimmed = std.mem.trimEnd(u8, url, "/");
    const uri = try std.Uri.parse(trimmed);
    return if (uri.path.isEmpty()) std.fmt.allocPrint(alloc, "{s}/v1", .{trimmed}) else alloc.dupe(u8, trimmed);
}

pub fn validate(entry: Entry) !void {
    if (!validName(entry.name) or entry.api_key.len == 0) return error.InvalidCompatibleProvider;
    for (entry.api_key) |c| if (std.ascii.isControl(c)) return error.InvalidCompatibleProvider;
    const uri = try std.Uri.parse(entry.base_url);
    if (!std.mem.eql(u8, uri.scheme, "https") or uri.host == null or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return error.InvalidCompatibleEndpoint;
}

/// Load account-owned settings only; project files cannot redirect API keys.
pub fn load(alloc: std.mem.Allocator, hooks: auth.Hooks) !Registry {
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const ar = arena.allocator();
    if (hooks.lock.auth) return .{ .arena = arena, .entries = &.{} };
    const home = try @import("auth_load.zig").resolveHome(ar, hooks);
    const path = try std.fs.path.join(ar, &.{ home, ".pz", "providers.json" });
    const raw = std.Io.Dir.cwd().readFileAlloc(sys.io, path, ar, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{ .arena = arena, .entries = &.{} },
        else => return err,
    };
    const parsed = try std.json.parseFromSlice(struct { providers: []const Entry }, ar, raw, .{ .allocate = .alloc_always });
    for (parsed.value.providers, 0..) |entry, i| {
        try validate(entry);
        for (parsed.value.providers[0..i]) |previous| if (std.mem.eql(u8, previous.name, entry.name)) return error.DuplicateCompatibleProvider;
    }
    return .{ .arena = arena, .entries = parsed.value.providers };
}

pub fn initClient(alloc: std.mem.Allocator, name: []const u8, hooks: auth.Hooks) !openai.Client {
    var registry = try load(alloc, hooks);
    defer registry.deinit();
    const entry = registry.find(name) orelse return error.UnknownCompatibleProvider;
    return openai.Client.initCompatible(alloc, hooks, entry.name, entry.base_url, entry.api_key);
}

pub const Model = struct {
    id: []const u8,
    context_length: ?u64 = null,
    context_window: ?u64 = null,
    max_model_len: ?u64 = null,
};

/// Returned data and strings belong to alloc; use a catalog-owned arena.
pub fn fetchModels(alloc: std.mem.Allocator, entry: Entry, ca_file: ?[]const u8) ![]const Model {
    try validate(entry);
    const url = try std.fmt.allocPrint(alloc, "{s}/models", .{std.mem.trimEnd(u8, entry.base_url, "/")});
    const bearer = try std.fmt.allocPrint(alloc, "Bearer {s}", .{entry.api_key});
    var http = try flow.initHttpClient(alloc, ca_file);
    defer http.deinit();
    var req = try http.request(.GET, try std.Uri.parse(url), .{
        .extra_headers = &.{ .{ .name = "accept", .value = "application/json" }, .{ .name = "authorization", .value = bearer } },
        .redirect_behavior = .unhandled,
        .keep_alive = false,
    });
    defer req.deinit();
    if (req.connection) |conn| try flow.setSocketDeadlines(conn);
    try req.sendBodiless();
    var redirect_buf: [0]u8 = .{};
    var response = try req.receiveHead(&redirect_buf);
    if (response.head.status != .ok) return error.CompatibleModelCatalogFailed;
    var transfer_buf: [16384]u8 = undefined;
    var decomp: std.http.Decompress = undefined;
    var decomp_buf: [std.compress.flate.max_window_len]u8 = undefined;
    const reader = response.readerDecompressing(&transfer_buf, &decomp, &decomp_buf);
    const body = try reader.allocRemaining(alloc, .limited(16 * 1024 * 1024));
    const parsed = try std.json.parseFromSlice(struct { data: []const Model }, alloc, body, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    for (parsed.value.data) |model| {
        if (model.id.len == 0 or !std.unicode.utf8ValidateSlice(model.id)) return error.InvalidCompatibleModel;
        for (model.id) |c| if (std.ascii.isControl(c)) return error.InvalidCompatibleModel;
    }
    return parsed.value.data;
}

test "named endpoint validation rejects reserved names and credential-bearing URLs" {
    try validate(.{ .name = "dahl", .base_url = "https://example.com/v1", .api_key = "test" });
    try std.testing.expectError(error.InvalidCompatibleProvider, validate(.{ .name = "openai", .base_url = "https://example.com/v1", .api_key = "test" }));
    try std.testing.expectError(error.InvalidCompatibleEndpoint, validate(.{ .name = "custom", .base_url = "https://user:password@example.com/v1", .api_key = "test" }));
    try std.testing.expectError(error.InvalidCompatibleEndpoint, validate(.{ .name = "custom", .base_url = "http://example.com/v1", .api_key = "test" }));
}

/// Add or update one named endpoint without changing other providers.
pub fn save(alloc: std.mem.Allocator, entry: Entry, hooks: auth.Hooks) !void {
    if (hooks.lock.auth) return error.AuthStoreLocked;
    try validate(entry);
    var registry = try load(alloc, hooks);
    defer registry.deinit();
    var entries = std.ArrayList(Entry).empty;
    defer entries.deinit(alloc);
    var replaced = false;
    for (registry.entries) |existing| {
        if (std.mem.eql(u8, existing.name, entry.name)) {
            try entries.append(alloc, entry);
            replaced = true;
        } else try entries.append(alloc, existing);
    }
    if (!replaced) try entries.append(alloc, entry);
    try writeEntries(alloc, entries.items, hooks);
}

/// Remove only the selected named provider; preserve all other credentials.
pub fn remove(alloc: std.mem.Allocator, name: []const u8, hooks: auth.Hooks) !void {
    if (hooks.lock.auth) return error.AuthStoreLocked;
    var registry = try load(alloc, hooks);
    defer registry.deinit();
    if (registry.find(name) == null) return error.UnknownCompatibleProvider;
    var entries = std.ArrayList(Entry).empty;
    defer entries.deinit(alloc);
    for (registry.entries) |entry| {
        if (!std.mem.eql(u8, entry.name, name)) try entries.append(alloc, entry);
    }
    try writeEntries(alloc, entries.items, hooks);
}

fn writeEntries(alloc: std.mem.Allocator, entries: []const Entry, hooks: auth.Hooks) !void {
    const home = try @import("auth_load.zig").resolveHome(alloc, hooks);
    defer alloc.free(home);
    const dir_path = try std.fs.path.join(alloc, &.{ home, ".pz" });
    defer alloc.free(dir_path);
    const secure = @import("../fs_secure.zig");
    try secure.ensureDirPath(dir_path);
    var dir = try std.Io.Dir.openDirAbsolute(sys.io, dir_path, .{});
    defer dir.close(sys.io);
    const data = try std.json.Stringify.valueAlloc(alloc, .{ .providers = entries }, .{ .whitespace = .indent_2 });
    defer alloc.free(data);
    try secure.atomicWriteAt(dir, "providers.json", data);
}

test "saving named providers preserves other endpoints and replaces only matching names" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(home);
    const hooks = auth.Hooks{ .home_override = home };
    try save(alloc, .{ .name = "first", .base_url = "https://first.example/v1", .api_key = "first-test-key" }, hooks);
    try save(alloc, .{ .name = "second", .base_url = "https://second.example/v1", .api_key = "second-test-key" }, hooks);
    try save(alloc, .{ .name = "first", .base_url = "https://updated.example/v1", .api_key = "updated-test-key" }, hooks);
    var registry = try load(alloc, hooks);
    defer registry.deinit();
    try std.testing.expectEqual(@as(usize, 2), registry.entries.len);
    try std.testing.expectEqualStrings("https://updated.example/v1", registry.find("first").?.base_url);
    try std.testing.expectEqualStrings("updated-test-key", registry.find("first").?.api_key);
    try std.testing.expectEqualStrings("second-test-key", registry.find("second").?.api_key);
    try std.testing.expect(registry.find("missing") == null);
    const stat = try tmp.dir.statFile(std.testing.io, ".pz/providers.json", .{});
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
}

test "configured client owns its endpoint and credentials independently of registry memory" {
    const alloc = std.testing.allocator;
    var client = try openai.Client.initCompatible(alloc, .{}, "custom", "https://example.com/v1/", "test-key");
    defer client.deinit();
    try std.testing.expectEqualStrings("https://example.com/v1/responses", client.endpoint.?);
    try std.testing.expectEqualStrings("custom", client.compatible_name.?);
    try std.testing.expectEqualStrings("test-key", client.auth.auth.api_key);
    try std.testing.expect(!client.isSub());
}

test "removing one compatible provider preserves other credentials and honors auth lock" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(home);
    const hooks = auth.Hooks{ .home_override = home };
    try save(alloc, .{ .name = "Tokenator", .base_url = "https://api.tokenator.cloud/v1", .api_key = "test-tokenator" }, hooks);
    try save(alloc, .{ .name = "Dahl", .base_url = "https://inference.dahl.global/v1", .api_key = "test-dahl" }, hooks);
    var locked = hooks;
    locked.lock.auth = true;
    try std.testing.expectError(error.AuthStoreLocked, remove(alloc, "Tokenator", locked));
    try remove(alloc, "Tokenator", hooks);
    var remaining = try load(alloc, hooks);
    defer remaining.deinit();
    try std.testing.expect(remaining.find("Tokenator") == null);
    try std.testing.expectEqualStrings("test-dahl", remaining.find("Dahl").?.api_key);
    try std.testing.expectError(error.UnknownCompatibleProvider, remove(alloc, "missing", hooks));
    try remove(alloc, "Dahl", hooks);
    var empty = try load(alloc, hooks);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.entries.len);
}
