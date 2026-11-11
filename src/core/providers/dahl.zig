//! Dahl reports the API key's allocated tokens, not the account pool or currency.
const std = @import("std");
const quota = @import("limits.zig");

pub fn isEndpoint(endpoint: []const u8) bool {
    return std.mem.eql(u8, endpoint, "https://inference.dahl.global/v1/responses");
}

pub fn fetchLimits(alloc: std.mem.Allocator, key: []const u8, ca_file: ?[]const u8) !quota.Limits {
    const flow = @import("oauth_flow.zig");
    var http = try flow.initHttpClient(alloc, ca_file);
    defer http.deinit();
    const bearer = try std.fmt.allocPrint(alloc, "Bearer {s}", .{key});
    defer alloc.free(bearer);
    var req = try http.request(.GET, try std.Uri.parse("https://inference.dahl.global/tokens/current"), .{
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
    if (response.head.status != .ok) return error.DahlQuotaRequestFailed;
    var transfer_buf: [16384]u8 = undefined;
    var decomp: std.http.Decompress = undefined;
    var decomp_buf: [std.compress.flate.max_window_len]u8 = undefined;
    const reader = response.readerDecompressing(&transfer_buf, &decomp, &decomp_buf);
    const body = try reader.allocRemaining(alloc, .limited(1024 * 1024));
    defer alloc.free(body);
    return parseLimits(alloc, body);
}

pub fn parseLimits(alloc: std.mem.Allocator, body: []const u8) !quota.Limits {
    const parsed = try std.json.parseFromSlice(struct { available_tokens: u64 }, alloc, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return .{ .token_billing = true, .available_tokens = parsed.value.available_tokens };
}

test "Dahl preserves actual key balance including zero without inferring spending" {
    const result = try parseLimits(std.testing.allocator, "{\"available_tokens\":97452244}");
    try std.testing.expectEqual(@as(u64, 97452244), result.available_tokens.?);
    try std.testing.expect(result.token_balance == null and result.free_tokens == null);
    const empty = try parseLimits(std.testing.allocator, "{\"available_tokens\":0}");
    try std.testing.expectEqual(@as(u64, 0), empty.available_tokens.?);
    try std.testing.expect(isEndpoint("https://inference.dahl.global/v1/responses"));
    try std.testing.expect(!isEndpoint("https://other.example/v1/responses"));
}
