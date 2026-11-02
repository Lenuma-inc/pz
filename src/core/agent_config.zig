//! Config directories must not be writable by sandboxed commands.
const std = @import("std");
pub const dirs = [_][]const u8{".pz"};

pub fn isPath(path: []const u8) bool {
    var parts = std.fs.path.componentIterator(path);
    while (parts.next()) |part| {
        for (dirs) |name| if (std.mem.eql(u8, part.name, name)) return true;
    }
    return false;
}

test "only pz config requires special approval" {
    try std.testing.expect(isPath("/home/user/.pz/settings.json"));
    try std.testing.expect(!isPath(".codex/config.toml"));
    try std.testing.expect(!isPath(".claude/settings.json"));
}
