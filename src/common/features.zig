const std = @import("std");
const c = @import("constants.zig");
const mcc = @import("mcc.zig");

pub const Transaction = struct {
    amount: f64,
    installments: u32,
    customer_avg_amount: f64,
    timestamp_seconds: i64,
    timestamp_dow: u8,
    timestamp_hour: u8,
    minutes_since_last: f64,
    km_since_last: f64,
    km_from_home: f64,
    tx_count_24h: u32,
    is_online: bool,
    card_present: bool,
    mcc: []const u8,
    merchant_known: bool,
    merchant_avg_amount: f64,
    last_tx_seconds: i64,
};

const AMOUNT_MAX: f32 = 10000.0;
const INSTALLMENTS_MAX: f32 = 12.0;
const MINUTES_MAX: f32 = 1440.0;
const KM_MAX: f32 = 1000.0;
const TX_COUNT_MAX: f32 = 20.0;
const MERCHANT_AVG_MAX: f32 = 10000.0;

/// round4: arredonda para 4 casas decimais. CRÍTICO para o vetor da query
/// bater com o vetor de referência usado pelo k-means / IVF (o gerador
/// oficial faz round4 em cada dim).
pub fn round4(v: f32) f32 {
    return @round(v * 10000.0) / 10000.0;
}

pub fn build(tx: *const Transaction) [c.DIM]f32 {
    var v: [c.DIM]f32 = undefined;
    v[0] = clamp01(@as(f32, @floatCast(tx.amount)) / AMOUNT_MAX);
    v[1] = clamp01(@as(f32, @floatFromInt(tx.installments)) / INSTALLMENTS_MAX);

    const ratio = if (tx.customer_avg_amount > 0.0)
        @as(f32, @floatCast(tx.amount / tx.customer_avg_amount / 10.0))
    else
        0.5;
    v[2] = clamp01(ratio);

    v[3] = @as(f32, @floatFromInt(tx.timestamp_hour)) / 23.0;
    v[4] = @as(f32, @floatFromInt(tx.timestamp_dow)) / 6.0;

    v[5] = if (tx.last_tx_seconds <= 0)
        -1.0
    else
        clamp01(@as(f32, @floatCast(tx.minutes_since_last)) / MINUTES_MAX);

    v[6] = if (tx.last_tx_seconds <= 0)
        -1.0
    else
        clamp01(@as(f32, @floatCast(tx.km_since_last)) / KM_MAX);

    v[7] = clamp01(@as(f32, @floatCast(tx.km_from_home)) / KM_MAX);
    v[8] = clamp01(@as(f32, @floatFromInt(tx.tx_count_24h)) / TX_COUNT_MAX);
    v[9] = if (tx.is_online) 1.0 else 0.0;
    v[10] = if (tx.card_present) 1.0 else 0.0;
    v[11] = if (tx.merchant_known) 0.0 else 1.0;
    v[12] = mcc.risk(tx.mcc);
    v[13] = clamp01(@as(f32, @floatCast(tx.merchant_avg_amount)) / MERCHANT_AVG_MAX);

    comptime var d: usize = 0;
    inline while (d < c.DIM) : (d += 1) {
        if (v[d] >= 0.0) v[d] = round4(v[d]);
    }
    return v;
}

inline fn clamp01(x: f32) f32 {
    if (x < 0.0) return 0.0;
    if (x > 1.0) return 1.0;
    return x;
}

test "build features within [0,1] or -1 sentinel" {
    const testing = std.testing;
    const tx = Transaction{
        .amount = 250.0,
        .installments = 1,
        .customer_avg_amount = 100.0,
        .timestamp_seconds = 1_700_000_000,
        .timestamp_dow = 2,
        .timestamp_hour = 14,
        .minutes_since_last = 60.0,
        .km_since_last = 12.0,
        .km_from_home = 5.0,
        .tx_count_24h = 3,
        .is_online = false,
        .card_present = true,
        .mcc = "5411",
        .merchant_known = true,
        .merchant_avg_amount = 200.0,
        .last_tx_seconds = 1_699_999_000,
    };
    const v = build(&tx);
    try testing.expectApproxEqAbs(@as(f32, 0.025), v[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 12.0), v[1], 1e-6);
    try testing.expectEqual(@as(f32, 0.0), v[9]);
    try testing.expectEqual(@as(f32, 1.0), v[10]);
    try testing.expectEqual(@as(f32, 0.0), v[11]);
    try testing.expectEqual(@as(f32, 0.15), v[12]);
}
test "minutes/km sentinels when no last tx" {
    const testing = std.testing;
    var tx = Transaction{
        .amount = 0.0,
        .installments = 0,
        .customer_avg_amount = 0.0,
        .timestamp_seconds = 0,
        .timestamp_dow = 0,
        .timestamp_hour = 0,
        .minutes_since_last = 999.0,
        .km_since_last = 999.0,
        .km_from_home = 0.0,
        .tx_count_24h = 0,
        .is_online = false,
        .card_present = false,
        .mcc = "9999",
        .merchant_known = false,
        .merchant_avg_amount = 0.0,
        .last_tx_seconds = 0,
    };
    var v = build(&tx);
    try testing.expectEqual(@as(f32, -1.0), v[5]);
    try testing.expectEqual(@as(f32, -1.0), v[6]);
    try testing.expectEqual(@as(f32, 1.0), v[11]);

    tx.last_tx_seconds = 1;
    v = build(&tx);
    try testing.expect(v[5] >= 0.0);
}
