//! Test harness: agent exit-code scenarios.
const sys = @import("pz_io");
const std = @import("std");
const agent = @import("core_agent");

pub fn main(init: std.process.Init) !void {
    sys.io = init.io;
    sys.env = init.minimal.environ;
    const alloc = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(alloc);
    if (argv.len != 2) return error.InvalidArgs;

    if (std.mem.eql(u8, argv[1], "version")) {
        agent.exitOnVersionMismatch(error.UnsupportedVersion);
        return error.TestUnexpectedResult;
    }
    if (std.mem.eql(u8, argv[1], "other")) {
        agent.exitOnVersionMismatch(error.EmptyPrompt);
        return;
    }

    return error.InvalidArgs;
}
