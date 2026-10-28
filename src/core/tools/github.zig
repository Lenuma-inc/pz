//! Browse GitHub contents one directory or file at a time, as in ghgrab's contents API flow.
const std = @import("std");
const tools = @import("../tools.zig");
const web = @import("web.zig");
const shared = @import("shared.zig");

pub fn run(alloc: std.mem.Allocator, max_bytes: usize, policy: web.RedirectPolicy, call: tools.Call) !tools.Result {
    const args = call.args.github;
    if (args.op == .read and args.path.len == 0) return error.InvalidArgs;
    if (args.from_line == 0 or args.to_line != null and args.to_line.? < args.from_line) return error.InvalidArgs;
    const url = try apiUrlAlloc(alloc, args);
    defer alloc.free(url);
    const response = try web.fetchAlloc(alloc, .{
        .url = url,
        .headers = &.{
            .{ .name = "Accept", .value = if (args.op == .read) "application/vnd.github.raw+json" else "application/vnd.github+json" },
            .{ .name = "User-Agent", .value = "pz" },
        },
    }, policy, 2 * 1024 * 1024);
    defer alloc.free(response.body);
    switch (response.status) {
        200 => {},
        401 => return error.Unauthorized,
        403, 429 => return error.GitHubRateLimited,
        404 => return error.NotFound,
        else => return error.GitHubHttpStatus,
    }
    const text = switch (args.op) {
        .list => try listAlloc(alloc, response.body),
        .read => try readLinesAlloc(alloc, response.body, args.from_line, args.to_line),
    };
    errdefer alloc.free(text);
    if (text.len > max_bytes) return error.TooLarge;
    return shared.buildResult(alloc, call.id, call.at_ms, text, max_bytes, text.len);
}

pub fn apiUrlAlloc(alloc: std.mem.Allocator, args: tools.Call.GithubArgs) ![]u8 {
    const repo = if (std.mem.startsWith(u8, args.repo, "https://github.com/")) args.repo[19..] else args.repo;
    var parts = std.mem.splitScalar(u8, repo, '/');
    const owner = parts.next() orelse return error.InvalidArgs;
    const name = parts.next() orelse return error.InvalidArgs;
    if (parts.next() != null or owner.len == 0 or name.len == 0) return error.InvalidArgs;
    for (owner) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-') return error.InvalidArgs;
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, "-_.", ch) == null) return error.InvalidArgs;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidArgs;
    if (std.mem.startsWith(u8, args.path, "/") or std.mem.indexOfScalar(u8, args.path, '\\') != null) return error.InvalidArgs;
    var path = std.mem.splitScalar(u8, args.path, '/');
    while (path.next()) |seg| if (std.mem.eql(u8, seg, "..") or std.mem.eql(u8, seg, ".")) return error.InvalidArgs;
    var out = std.Io.Writer.Allocating.init(alloc);
    errdefer out.deinit();
    try out.writer.print("https://api.github.com/repos/{s}/{s}/contents", .{ owner, name });
    if (args.path.len > 0) {
        try out.writer.writeByte('/');
        try std.Uri.Component.percentEncode(&out.writer, args.path, pathChar);
    }
    if (args.ref) |ref| {
        if (ref.len == 0) return error.InvalidArgs;
        try out.writer.writeAll("?ref=");
        try std.Uri.Component.percentEncode(&out.writer, ref, unreserved);
    }
    return out.toOwnedSlice();
}

fn unreserved(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "-._~", ch) != null;
}

fn pathChar(ch: u8) bool {
    return ch == '/' or unreserved(ch);
}

pub fn listAlloc(alloc: std.mem.Allocator, body: []const u8) ![]u8 {
    const Item = struct { path: []const u8, type: []const u8, size: u64 = 0 };
    const parsed = try std.json.parseFromSlice([]const Item, alloc, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (parsed.value.len >= 1000) return error.GitHubDirectoryLimit;
    var out = std.Io.Writer.Allocating.init(alloc);
    errdefer out.deinit();
    for (parsed.value) |item| try out.writer.print("{s}\t{s}\t{d} bytes\n", .{ item.type, item.path, item.size });
    return out.toOwnedSlice();
}

pub fn readLinesAlloc(alloc: std.mem.Allocator, body: []const u8, from: u32, to: ?u32) ![]u8 {
    if (std.mem.indexOfScalar(u8, body, 0) != null or !std.unicode.utf8ValidateSlice(body)) return error.BinaryFile;
    var out = std.Io.Writer.Allocating.init(alloc);
    errdefer out.deinit();
    var lines = std.mem.splitScalar(u8, body, '\n');
    var n: u32 = 0;
    while (lines.next()) |line| {
        if (line.len == 0 and lines.index == null) break;
        n += 1;
        if (to) |end| if (n > end) break;
        if (n >= from) try out.writer.print("{d}: {s}\n", .{ n, line });
    }
    return out.toOwnedSlice();
}
