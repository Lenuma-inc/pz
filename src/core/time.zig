const std = @import("std");
const sys = @import("pz_io");

pub fn milliTimestamp() i64 {
    return std.Io.Clock.real.now(sys.io).toMilliseconds();
}

pub fn microTimestamp() i64 {
    return std.Io.Clock.real.now(sys.io).toMicroseconds();
}

pub fn nanoTimestamp() i128 {
    return std.Io.Clock.real.now(sys.io).nanoseconds;
}
