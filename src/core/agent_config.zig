//! Config directories must not be writable by sandboxed commands.
const std = @import("std");
pub const dirs = [_][]const u8{ ".pz", ".codex", ".claude" };

pub fn isPath(path: []const u8) bool {
    var parts = std.fs.path.componentIterator(path);
    while (parts.next()) |part| {
        for (dirs) |name| if (std.mem.eql(u8, part.name, name)) return true;
    }
    return false;
}
