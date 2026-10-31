//! Focused MCP suite, independent of agent subprocess harnesses.
test {
    _ = @import("core/mcp.zig");
    _ = @import("core/loop.zig");
    _ = @import("core/tools/builtin.zig");
    _ = @import("app/config.zig");
    _ = @import("app/runtime.zig");
}
