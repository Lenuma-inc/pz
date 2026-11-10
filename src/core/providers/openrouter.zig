//! OpenRouter Responses API client. Browser sign-in yields a regular API key.
const std = @import("std");
const openai = @import("openai.zig");
const hc = @import("http_client.zig");

pub const Cfg = openai.Config(.openrouter);
pub const Client = hc.SseClient(Cfg);

/// Owned API model IDs and their reported context capacities.
pub const Catalog = struct {
    ids: [][]const u8,
    context_windows: std.StringHashMapUnmanaged(u64),

    pub fn deinit(self: *Catalog, alloc: std.mem.Allocator) void {
        self.context_windows.deinit(alloc);
        for (self.ids) |id| alloc.free(id);
        alloc.free(self.ids);
    }
};

pub fn fetchModels(alloc: std.mem.Allocator, ca_file: ?[]const u8) !Catalog {
    const body = try getJson(alloc, "/api/v1/models", null, ca_file);
    defer alloc.free(body);
    return parseModels(alloc, body);
}

/// Read the account-wide free request quota reported for this API key.
pub fn fetchLimits(alloc: std.mem.Allocator, key: []const u8, ca_file: ?[]const u8) !?@import("limits.zig").Limits {
    const body = try getJson(alloc, "/api/v1/key", key, ca_file);
    defer alloc.free(body);
    return parseLimits(alloc, body);
}

pub fn parseLimits(alloc: std.mem.Allocator, body: []const u8) !?@import("limits.zig").Limits {
    const parsed = try std.json.parseFromSlice(struct {
        data: struct {
            free_model_daily_requests: ?struct { used: u64, limit: u64, remaining: u64 } = null,
            limit: ?f64 = null,
            limit_remaining: ?f64 = null,
        },
    }, alloc, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var result: @import("limits.zig").Limits = .{};
    if (parsed.value.data.free_model_daily_requests) |daily| {
        if (daily.remaining > daily.limit) return error.InvalidQuota;
        result.free_requests = .{ .used = daily.used, .limit = daily.limit, .remaining = daily.remaining };
    }
    if (parsed.value.data.limit) |limit| {
        const remaining = parsed.value.data.limit_remaining orelse return error.InvalidQuota;
        if (!std.math.isFinite(limit) or limit < 0 or !std.math.isFinite(remaining)) return error.InvalidQuota;
        result.key_credit_limit = .{ .limit = limit, .remaining = remaining };
    }
    return result;
}

fn getJson(alloc: std.mem.Allocator, path: []const u8, key: ?[]const u8, ca_file: ?[]const u8) ![]u8 {
    const flow = @import("oauth_flow.zig");
    var http = try flow.initHttpClient(alloc, ca_file);
    defer http.deinit();
    const bearer = if (key) |value| try std.fmt.allocPrint(alloc, "Bearer {s}", .{value}) else null;
    defer if (bearer) |value| alloc.free(value);
    var headers: [2]std.http.Header = undefined;
    headers[0] = .{ .name = "accept", .value = "application/json" };
    if (bearer) |value| headers[1] = .{ .name = "authorization", .value = value };
    var req = try http.request(.GET, .{
        .scheme = "https",
        .host = .{ .raw = "openrouter.ai" },
        .path = .{ .raw = path },
    }, .{
        .extra_headers = headers[0..if (bearer != null) @as(usize, 2) else 1],
        .keep_alive = false,
        .redirect_behavior = .unhandled,
    });
    defer req.deinit();
    if (req.connection) |conn| try flow.setSocketDeadlines(conn);
    try req.sendBodiless();
    var redirect_buf: [0]u8 = .{};
    var response = try req.receiveHead(&redirect_buf);
    if (response.head.status != .ok) return switch (@intFromEnum(response.head.status)) {
        301, 302, 303, 307, 308 => error.OpenRouterHttpRedirect,
        400 => error.OpenRouterHttp400,
        401 => error.OpenRouterHttp401,
        402 => error.OpenRouterHttp402,
        403 => error.OpenRouterHttp403,
        404 => error.OpenRouterHttp404,
        429 => error.OpenRouterHttp429,
        500 => error.OpenRouterHttp500,
        502 => error.OpenRouterHttp502,
        503 => error.OpenRouterHttp503,
        else => error.OpenRouterApiRequestFailed,
    };
    var transfer_buf: [16384]u8 = undefined;
    var decomp: std.http.Decompress = undefined;
    var decomp_buf: [std.compress.flate.max_window_len]u8 = undefined;
    const reader = response.readerDecompressing(&transfer_buf, &decomp, &decomp_buf);
    return reader.allocRemaining(alloc, .limited(16 * 1024 * 1024));
}

/// Decode model IDs from the API trust boundary, without a built-in catalog.
pub fn parseModels(alloc: std.mem.Allocator, body: []const u8) !Catalog {
    const parsed = try std.json.parseFromSlice(struct {
        data: []const struct { id: []const u8, context_length: ?u64 = null },
    }, alloc, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var windows = std.StringHashMapUnmanaged(u64).empty;
    errdefer windows.deinit(alloc);
    var ids = std.ArrayList([]const u8).empty;
    errdefer {
        for (ids.items) |id| alloc.free(id);
        ids.deinit(alloc);
    }
    for (parsed.value.data) |entry| {
        if (entry.id.len == 0 or std.mem.indexOfScalar(u8, entry.id, '/') == null or
            !std.unicode.utf8ValidateSlice(entry.id)) return error.InvalidModelCatalog;
        for (entry.id) |c| if (std.ascii.isControl(c)) return error.InvalidModelCatalog;
        const id = try alloc.dupe(u8, entry.id);
        ids.append(alloc, id) catch |err| {
            alloc.free(id);
            return err;
        };
        if (entry.context_length) |length| {
            if (length > 0) try windows.put(alloc, id, length);
        }
    }
    return .{ .ids = try ids.toOwnedSlice(alloc), .context_windows = windows };
}

test "OpenRouter catalog reads API IDs and rejects invalid entries" {
    const alloc = std.testing.allocator;
    var catalog = try parseModels(alloc, "{\"data\":[{\"id\":\"vendor/new-model\",\"name\":\"New\",\"context_length\":131072},{\"id\":\"openrouter/free\"}]}");
    defer catalog.deinit(alloc);
    const ids = catalog.ids;
    try std.testing.expectEqual(@as(usize, 2), ids.len);
    try std.testing.expectEqualStrings("vendor/new-model", ids[0]);
    try std.testing.expectEqualStrings("openrouter/free", ids[1]);
    try std.testing.expectEqual(@as(u64, 131072), catalog.context_windows.get(ids[0]).?);
    try std.testing.expect(catalog.context_windows.get(ids[1]) == null);
    try std.testing.expectError(error.InvalidModelCatalog, parseModels(alloc, "{\"data\":[{\"id\":\"\"}]}"));
    try std.testing.expectError(error.MissingField, parseModels(alloc, "{}"));
}

test "OpenRouter uses its Responses endpoint and shared event parser" {
    const uri = Cfg.apiUri(false);
    try std.testing.expectEqualStrings("openrouter.ai", uri.host.?.raw);
    try std.testing.expectEqualStrings("/api/v1/responses", uri.path.raw);
    var stream = hc.SseStream(Cfg).initFields(std.testing.allocator);
    defer {
        Cfg.ext_deinit(&stream, std.testing.allocator);
        stream.tool_name.deinit(std.testing.allocator);
        stream.tool_args.deinit(std.testing.allocator);
        stream.arena.deinit();
    }
    const event = (try Cfg.parseSseData(&stream, "{\"type\":\"response.output_text.delta\",\"delta\":\"hello\"}")) orelse return error.MissingEvent;
    _ = event;
}

test "OpenRouter free request quota uses API remaining rather than inferred counts" {
    const alloc = std.testing.allocator;
    const quota = (try parseLimits(alloc, "{\"data\":{\"free_model_daily_requests\":{\"used\":12,\"limit\":50,\"remaining\":38}}}")).?;
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("free: 38/50 requests left (UTC day)", try @import("limits.zig").format(quota, &buf));
    const missing = try parseLimits(alloc, "{\"data\":{}}");
    try std.testing.expectEqualStrings("limits: free quota not reported", try @import("limits.zig").formatForModel(missing, "openrouter/free", &buf));
    try std.testing.expectError(error.InvalidQuota, parseLimits(alloc, "{\"data\":{\"free_model_daily_requests\":{\"used\":0,\"limit\":50,\"remaining\":51}}}"));
}

test "stream next preserves API quotas when HTTP headers contain no limits" {
    var stream = hc.SseStream(Cfg).initFields(std.testing.allocator);
    defer {
        Cfg.ext_deinit(&stream, std.testing.allocator);
        stream.tool_name.deinit(std.testing.allocator);
        stream.tool_args.deinit(std.testing.allocator);
        stream.arena.deinit();
    }
    stream.pending = .{ .usage = .{ .limits = .{ .free_requests = .{ .used = 12, .limit = 50, .remaining = 38 } } } };
    stream.limits = null;
    const event = (try stream.next()).?;
    try std.testing.expectEqual(@as(u64, 38), event.usage.limits.?.free_requests.?.remaining);
}

test "quota credentials survive event arena reuse" {
    const alloc = std.testing.allocator;
    var stream = hc.SseStream(Cfg).initFields(alloc);
    defer {
        if (stream.quota_key) |key| alloc.free(key);
        if (stream.quota_ca_file) |path| alloc.free(path);
        Cfg.ext_deinit(&stream, alloc);
        stream.tool_name.deinit(alloc);
        stream.tool_args.deinit(alloc);
        stream.arena.deinit();
    }
    try stream.initQuotaAuth("sk-or-test", "/test/ca.pem");
    _ = try stream.arena.allocator().dupe(u8, "first event");
    _ = stream.arena.reset(.retain_capacity);
    const overwritten = try stream.arena.allocator().alloc(u8, 128);
    @memset(overwritten, 'x');
    try std.testing.expectEqualStrings("sk-or-test", stream.quota_key.?);
    try std.testing.expectEqualStrings("/test/ca.pem", stream.quota_ca_file.?);
}

test "paid models show API key credit caps instead of free request quota" {
    const alloc = std.testing.allocator;
    const limits = try parseLimits(alloc, "{\"data\":{\"limit\":10,\"limit_remaining\":3.25,\"free_model_daily_requests\":{\"used\":4,\"limit\":50,\"remaining\":46}}}");
    const quota = @import("limits.zig");
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("key: $3.25/$10.00 left", try quota.formatForModel(limits, "vendor/paid-model", &buf));
    try std.testing.expectEqualStrings("free: 46/50 requests left (UTC day)", try quota.formatForModel(limits, "vendor/model:free", &buf));
    try std.testing.expectEqualStrings("free: 46/50 requests left (UTC day)", try quota.formatForModel(limits, "openrouter/free", &buf));
    const unlimited = try parseLimits(alloc, "{\"data\":{\"limit\":null,\"limit_remaining\":null}}");
    try std.testing.expectEqualStrings("key: no spending limit", try quota.formatForModel(unlimited, "vendor/paid-model", &buf));
    const exhausted = try parseLimits(alloc, "{\"data\":{\"limit\":0,\"limit_remaining\":0}}");
    try std.testing.expectEqualStrings("key: $0.00/$0.00 left", try quota.formatForModel(exhausted, "vendor/paid-model", &buf));
    try std.testing.expectError(error.InvalidQuota, parseLimits(alloc, "{\"data\":{\"limit\":10,\"limit_remaining\":null}}"));
    try std.testing.expectError(error.InvalidQuota, parseLimits(alloc, "{\"data\":{\"limit\":-1,\"limit_remaining\":0}}"));
}
