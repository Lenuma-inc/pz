const std = @import("std");
const builtin = @import("builtin");

pub var io: std.Io = if (builtin.is_test) std.testing.io else undefined;
pub var env: std.process.Environ = undefined;

pub fn environ() std.process.Environ {
    return if (builtin.is_test) std.testing.environ else env;
}

pub fn nowMs() i64 {
    return std.Io.Clock.real.now(io).toMilliseconds();
}
