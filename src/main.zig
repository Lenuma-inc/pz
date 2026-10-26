//! Entry point.
const sys = @import("pz_io");
const std = @import("std");
const app = @import("app.zig");

pub fn main(init: std.process.Init) !u8 {
    sys.io = init.io;
    sys.env = init.minimal.environ;
    return try app.run(init);
}
