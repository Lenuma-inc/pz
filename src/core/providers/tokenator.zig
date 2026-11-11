//! Tokenator key balances: reported billing tokens, never inferred currency.
const std = @import("std");
const quota = @import("limits.zig");

pub fn isEndpoint(endpoint: []const u8) bool {
    return std.mem.eql(u8, endpoint, "https://api.tokenator.cloud/v1/responses");
}

pub fn fetchLimits(alloc: std.mem.Allocator, key: []const u8, model: []const u8, ca_file: ?[]const u8) !quota.Limits {
    const flow = @import("oauth_flow.zig");
    var http = try flow.initHttpClient(alloc, ca_file);
    defer http.deinit();
    const bearer = try std.fmt.allocPrint(alloc, "Bearer {s}", .{key});
    defer alloc.free(bearer);
    var req = try http.request(.GET, try std.Uri.parse("https://api.tokenator.cloud/v1/tokens"), .{
        .extra_headers = &.{
            .{ .name = "accept", .value = "application/json" },
            .{ .name = "authorization", .value = bearer },
        },
        .keep_alive = false,
        .redirect_behavior = .unhandled,
    });
    defer req.deinit();
    if (req.connection) |conn| try flow.setSocketDeadlines(conn);
    try req.sendBodiless();
    var redirect_buf: [0]u8 = .{};
    var response = try req.receiveHead(&redirect_buf);
    if (response.head.status != .ok) return error.TokenatorQuotaRequestFailed;
    var transfer_buf: [16384]u8 = undefined;
    var decomp: std.http.Decompress = undefined;
    var decomp_buf: [std.compress.flate.max_window_len]u8 = undefined;
    const reader = response.readerDecompressing(&transfer_buf, &decomp, &decomp_buf);
    const body = try reader.allocRemaining(alloc, .limited(1024 * 1024));
    defer alloc.free(body);
    return parseLimits(alloc, body, model);
}

pub fn parseLimits(alloc: std.mem.Allocator, body: []const u8, model: []const u8) !quota.Limits {
    const parsed = try std.json.parseFromSlice(struct {
        limit: u64,
        used: u64,
        remaining: u64,
        free_models: []const struct {
            model: []const u8,
            daily_tokens: ?u64 = null,
            tokens_used: ?u64 = null,
            tokens_remaining: ?u64 = null,
            daily_requests: ?u64 = null,
            requests_used: ?u64 = null,
            requests_remaining: ?u64 = null,
        } = &.{},
    }, alloc, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const value = parsed.value;
    try validateBalance(value.used, value.remaining, value.limit);
    var out: quota.Limits = .{ .token_billing = true, .token_balance = .{ .used = value.used, .remaining = value.remaining, .limit = value.limit } };
    for (value.free_models) |free| {
        if (!std.mem.eql(u8, free.model, model)) continue;
        if (free.daily_tokens) |limit| {
            const used = free.tokens_used orelse return error.InvalidQuota;
            const remaining = free.tokens_remaining orelse return error.InvalidQuota;
            try validateBalance(used, remaining, limit);
            out.free_tokens = .{ .used = used, .remaining = remaining, .limit = limit };
        }
        if (free.daily_requests) |limit| {
            const used = free.requests_used orelse return error.InvalidQuota;
            const remaining = free.requests_remaining orelse return error.InvalidQuota;
            try validateBalance(used, remaining, limit);
            out.free_requests = .{ .used = used, .remaining = remaining, .limit = limit };
        }
        break;
    }
    return out;
}

fn validateBalance(used: u64, remaining: u64, limit: u64) !void {
    if (used > limit or remaining != limit - used) return error.InvalidQuota;
}

test "Tokenator parses selected free quota and paid balance independently" {
    const body =
        \\{"limit":3000000,"used":8771,"remaining":2991229,"free_models":[
        \\{"model":"free-other","daily_tokens":10,"tokens_used":10,"tokens_remaining":0},
        \\{"model":"free-test","daily_tokens":3500000,"tokens_used":9940,"tokens_remaining":3490060,"daily_requests":60,"requests_used":3,"requests_remaining":57,"resets_at":"tomorrow"}]}
    ;
    const result = try parseLimits(std.testing.allocator, body, "free-test");
    try std.testing.expectEqual(@as(u64, 8771), result.token_balance.?.used);
    try std.testing.expectEqual(@as(u64, 3490060), result.free_tokens.?.remaining);
    try std.testing.expectEqual(@as(u64, 57), result.free_requests.?.remaining);
    const paid = try parseLimits(std.testing.allocator, body, "paid-model");
    try std.testing.expect(paid.free_tokens == null and paid.free_requests == null);
}

test "Tokenator rejects inconsistent balances and accepts exhausted quotas" {
    try std.testing.expectError(error.InvalidQuota, parseLimits(std.testing.allocator, "{\"limit\":10,\"used\":11,\"remaining\":0}", "paid"));
    try std.testing.expectError(error.InvalidQuota, parseLimits(std.testing.allocator, "{\"limit\":10,\"used\":1,\"remaining\":10}", "paid"));
    const exhausted = try parseLimits(std.testing.allocator, "{\"limit\":10,\"used\":10,\"remaining\":0}", "paid");
    try std.testing.expectEqual(@as(u64, 0), exhausted.token_balance.?.remaining);
    try std.testing.expect(isEndpoint("https://api.tokenator.cloud/v1/responses"));
    try std.testing.expect(!isEndpoint("https://other.example/v1/responses"));
    try std.testing.expect(!isEndpoint("https://api.tokenator.cloud.evil/v1/responses"));
}
