const std = @import("std");

pub fn resolve(alloc: std.mem.Allocator, host: []const u8, port: u16) ![]std.Io.net.IpAddress {
    if (std.mem.indexOfScalar(u8, host, 0) != null) return error.InvalidHostName;
    const name = try alloc.dupeSentinel(u8, host, 0);
    defer alloc.free(name);
    var first: ?*std.c.addrinfo = null;
    var hints = std.mem.zeroes(std.c.addrinfo);
    hints.family = std.c.AF.UNSPEC;
    hints.socktype = std.c.SOCK.STREAM;
    if (@intFromEnum(std.c.getaddrinfo(name, null, &hints, &first)) != 0) return error.UnknownHostName;
    defer if (first) |ptr| std.c.freeaddrinfo(ptr);
    var addrs: std.ArrayList(std.Io.net.IpAddress) = .empty;
    errdefer addrs.deinit(alloc);
    var next = first;
    while (next) |item| : (next = item.next) {
        const sa = item.addr orelse continue;
        switch (sa.family) {
            std.c.AF.INET => {
                const ip: *const std.c.sockaddr.in = @ptrCast(@alignCast(sa));
                try addrs.append(alloc, .{ .ip4 = .{ .bytes = @bitCast(ip.addr), .port = port } });
            },
            std.c.AF.INET6 => {
                const ip: *const std.c.sockaddr.in6 = @ptrCast(@alignCast(sa));
                try addrs.append(alloc, .{ .ip6 = .{ .bytes = ip.addr, .port = port, .flow = ip.flowinfo, .interface = .{ .index = ip.scope_id } } });
            },
            else => {},
        }
    }
    if (addrs.items.len == 0) return error.UnknownHostName;
    return addrs.toOwnedSlice(alloc);
}

pub const SockAddr = extern union {
    ip4: std.c.sockaddr.in,
    ip6: std.c.sockaddr.in6,

    pub fn init(addr: std.Io.net.IpAddress) SockAddr {
        return switch (addr) {
            .ip4 => |ip| .{ .ip4 = .{ .port = std.mem.nativeToBig(u16, ip.port), .addr = @bitCast(ip.bytes) } },
            .ip6 => |ip| .{ .ip6 = .{ .port = std.mem.nativeToBig(u16, ip.port), .addr = ip.bytes, .flowinfo = ip.flow, .scope_id = ip.interface.index } },
        };
    }
};

test "resolve preserves loopback bytes and port" {
    const addrs = try resolve(std.testing.allocator, "127.0.0.1", 4321);
    defer std.testing.allocator.free(addrs);
    try std.testing.expect(addrs.len > 0);
    try std.testing.expectEqual(@as(u16, 4321), addrs[0].ip4.port);
    try std.testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, &addrs[0].ip4.bytes);
}

test "resolve handles DNS hostnames and rejects embedded nulls" {
    const addrs = try resolve(std.testing.allocator, "localhost", 4321);
    defer std.testing.allocator.free(addrs);
    try std.testing.expect(addrs.len > 0);
    for (addrs) |addr| try std.testing.expectEqual(@as(u16, 4321), addr.getPort());
    try std.testing.expectError(error.InvalidHostName, resolve(std.testing.allocator, "localhost\x00.invalid", 80));
}
