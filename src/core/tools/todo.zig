//! Session-local task list.
const std = @import("std");
const tools = @import("../tools.zig");
const shared = @import("shared.zig");

pub const State = struct {
    json: ?[]u8 = null,

    pub fn deinit(self: *State, alloc: std.mem.Allocator) void {
        if (self.json) |text| alloc.free(text);
        self.* = .{};
    }

    pub fn run(self: *State, alloc: std.mem.Allocator, max_bytes: usize, call: tools.Call) !tools.Result {
        if (call.args.todo.items) |items| {
            if (items.len > 100) return error.InvalidArgs;
            var active: usize = 0;
            for (items) |item| {
                if (std.mem.trim(u8, item.content, " \t\r\n").len == 0) return error.InvalidArgs;
                if (item.status == .in_progress) active += 1;
            }
            if (active > 1) return error.InvalidArgs;
            const text = try std.json.Stringify.valueAlloc(alloc, items, .{});
            errdefer alloc.free(text);
            if (text.len > max_bytes) return error.TooLarge;
            if (self.json) |old| alloc.free(old);
            self.json = text;
        }
        const text = try alloc.dupe(u8, self.json orelse "[]");
        errdefer alloc.free(text);
        return shared.buildResult(alloc, call.id, call.at_ms, text, max_bytes, text.len);
    }
};
