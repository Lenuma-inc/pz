/// Build repeated test text at compile time, including its string terminator.
pub fn text(comptime value: []const u8, comptime count: usize) *const [value.len * count:0]u8 {
    return comptime blk: {
        var result: [value.len * count:0]u8 = undefined;
        if (result.len != 0) {
            @memcpy(result[0..value.len], value);
            var filled: usize = value.len;
            while (filled < result.len) {
                const len = @min(filled, result.len - filled);
                @memcpy(result[filled..][0..len], result[0..len]);
                filled += len;
            }
        }
        result[result.len] = 0;
        const final = result;
        break :blk &final;
    };
}
