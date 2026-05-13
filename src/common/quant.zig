const std = @import("std");
const testing = std.testing;
const c = @import("constants.zig");

pub fn quantize(v: f32) i16 {
    if (v < 0.0) return c.SENTINEL_I16;
    const clamped = if (v > 1.0) 1.0 else v;
    const scaled = clamped * c.SCALE;
    return @as(i16, @intFromFloat(@round(scaled)));
}

pub fn quantize14(v: *const [c.DIM]f32) [c.DIM]i16 {
    var out: [c.DIM]i16 = undefined;
    comptime var d: usize = 0;
    inline while (d < c.DIM) : (d += 1) out[d] = quantize(v[d]);
    return out;
}

test "quantize 1.0 -> SCALE" {
    try testing.expectEqual(@as(i16, 10000), quantize(1.0));
}
test "quantize 0.0 -> 0" {
    try testing.expectEqual(@as(i16, 0), quantize(0.0));
}
test "quantize negative -> SENTINEL" {
    try testing.expectEqual(c.SENTINEL_I16, quantize(-0.5));
    try testing.expectEqual(c.SENTINEL_I16, quantize(-1.0));
}
test "quantize round-half-up" {
    try testing.expectEqual(@as(i16, 56), quantize(0.0056));
}
test "quantize14 array" {
    var v: [c.DIM]f32 = undefined;
    for (&v, 0..) |*x, i| x.* = @as(f32, @floatFromInt(i)) / 100.0;
    const q = quantize14(&v);
    try testing.expectEqual(@as(i16, 0), q[0]);
    try testing.expectEqual(@as(i16, 100), q[1]);
}
