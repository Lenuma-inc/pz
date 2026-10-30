//! User approvals for exact context-file bytes at an absolute path.
const std = @import("std");
const sys = @import("pz_io");
const fs = @import("fs_secure.zig");
const guard = @import("tools/path_guard.zig");

pub const Approval = struct {
    ctx: *anyopaque,
    check: *const fn (*anyopaque, []const u8, []const u8) anyerror!bool,
};

pub fn allow(alloc: std.mem.Allocator, home: ?[]const u8, path: []const u8, content: []const u8, approval: ?Approval) !bool {
    if (!std.fs.path.isAbsolute(path)) return error.InvalidContextPath;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(path);
    hash.update(&.{0});
    hash.update(content);
    const key = std.fmt.bytesToHex(hash.finalResult(), .lower);
    const cache = if (home) |h| try std.fs.path.join(alloc, &.{ h, ".pz", "context-trust" }) else null;
    defer if (cache) |c| alloc.free(c);

    if (cache) |c| {
        const dir = guard.openDir(c, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (dir) |d| {
            defer d.close(sys.io);
            const file = fs.openConfined(d, &key, .{}) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };
            if (file) |f| {
                defer f.close(sys.io);
                var buf: [32]u8 = undefined;
                var reader = f.readerStreaming(sys.io, &buf);
                const marker = try reader.interface.allocRemaining(alloc, .limited(32));
                defer alloc.free(marker);
                if (!std.mem.eql(u8, marker, "approved\n")) return error.InvalidContextTrust;
                return true;
            }
        }
    }
    const ask = approval orelse return error.ContextTrustRequired;
    if (!try ask.check(ask.ctx, path, content)) return false;
    if (cache) |c| {
        try fs.ensureDirPath(c);
        const dir = try guard.openDir(c, .{});
        defer dir.close(sys.io);
        try fs.atomicWriteAt(dir, &key, "approved\n");
    }
    return true;
}

test "context trust requires approval and binds exact path and bytes" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(home);
    const Ask = struct {
        calls: usize = 0,
        yes: bool = false,
        fn check(ptr: *anyopaque, path: []const u8, content: []const u8) !bool {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            try std.testing.expectEqualStrings("/project/AGENTS.md", path);
            try std.testing.expectEqualStrings("untrusted instructions", content);
            return self.yes;
        }
    };
    var ask = Ask{};
    const hook = Approval{ .ctx = &ask, .check = Ask.check };
    try std.testing.expectError(error.ContextTrustRequired, allow(a, home, "/project/AGENTS.md", "untrusted instructions", null));
    try std.testing.expect(!try allow(a, home, "/project/AGENTS.md", "untrusted instructions", hook));
    try std.testing.expectError(error.ContextTrustRequired, allow(a, home, "/project/AGENTS.md", "untrusted instructions", null));
    ask.yes = true;
    try std.testing.expect(try allow(a, home, "/project/AGENTS.md", "untrusted instructions", hook));
    try std.testing.expect(try allow(a, home, "/project/AGENTS.md", "untrusted instructions", null));
    try std.testing.expectEqual(@as(usize, 2), ask.calls);
    try std.testing.expectError(error.ContextTrustRequired, allow(a, home, "/project/AGENTS.md", "changed instructions", null));
    try std.testing.expectError(error.ContextTrustRequired, allow(a, home, "/other/AGENTS.md", "untrusted instructions", null));
}
