const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.addModule("dmp", .{
        .root_source_file = b.path("src/dmp.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    });
}
