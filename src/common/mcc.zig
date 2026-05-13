const std = @import("std");
const testing = std.testing;

pub const default_risk: f32 = 0.5;

const Entry = struct { mcc: []const u8, risk: f32 };
const table = [_]Entry{
    .{ .mcc = "4511", .risk = 0.35 },
    .{ .mcc = "5311", .risk = 0.25 },
    .{ .mcc = "5411", .risk = 0.15 },
    .{ .mcc = "5812", .risk = 0.30 },
    .{ .mcc = "5912", .risk = 0.20 },
    .{ .mcc = "5944", .risk = 0.45 },
    .{ .mcc = "5999", .risk = 0.50 },
    .{ .mcc = "7801", .risk = 0.80 },
    .{ .mcc = "7802", .risk = 0.75 },
    .{ .mcc = "7995", .risk = 0.85 },
};

pub fn risk(mcc_str: []const u8) f32 {
    inline for (table) |e| {
        if (std.mem.eql(u8, e.mcc, mcc_str)) return e.risk;
    }
    return default_risk;
}

test "known MCC" {
    try testing.expectEqual(@as(f32, 0.15), risk("5411"));
    try testing.expectEqual(@as(f32, 0.85), risk("7995"));
}
test "unknown MCC defaults to 0.5" {
    try testing.expectEqual(default_risk, risk("9999"));
    try testing.expectEqual(default_risk, risk(""));
}
