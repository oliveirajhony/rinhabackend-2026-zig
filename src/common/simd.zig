const std = @import("std");
const testing = std.testing;
const c = @import("constants.zig");

const V8i16 = @Vector(8, i16);
const V8i32 = @Vector(8, i32);
const V8u32 = @Vector(8, u32);
const V8f32 = @Vector(8, f32);

/// Distancia L2² query (i16) × centroids i16 dim-major SoA. Output u64 por
/// centroid. Acumulador em dois u32 halves (dims 0..7 e 8..13), somados em
/// u64 no fim — evita overflow do i32 single-acc quando 14 dims × ~4e8 = 5.6e9.
///
/// Mesma estrutura do steixeira93 (#4015 — 5931.39) que casa com vpmaddwd
/// em haswell.
pub fn centroidDistsFromQuery(
    query_i16: *const [c.DIM]i16,
    centroids_t: []align(1) const i16, // dim-major [c.DIM][NUM_CENTROIDS]
    out: []u64,
    num_centroids: usize,
) void {
    var ci: usize = 0;
    while (ci + 8 <= num_centroids) : (ci += 8) {
        // Lower half: dims 0..7. Max acc por lane: 8 × 4e8 = 3.2e9 < u32 max (4.3e9).
        var acc_lo: V8u32 = @splat(0);
        comptime var d: usize = 0;
        inline while (d < 8) : (d += 1) {
            const ptr: *align(1) const [8]i16 =
                @ptrCast(centroids_t[d * num_centroids + ci ..][0..8]);
            const cent_i16: V8i16 = ptr.*;
            const q_i16: V8i16 = @splat(query_i16[d]);
            const diff_i16 = cent_i16 - q_i16;
            const diff_i32: V8i32 = @intCast(diff_i16); // sign-extend i16 → i32
            const sq: V8i32 = diff_i32 * diff_i32; // i32 fits (max 4e8)
            acc_lo +%= @as(V8u32, @bitCast(sq));
        }
        // Upper half: dims 8..13 (6 dims). Max acc: 6 × 4e8 = 2.4e9 < u32 max.
        var acc_hi: V8u32 = @splat(0);
        comptime var d2: usize = 8;
        inline while (d2 < c.DIM) : (d2 += 1) {
            const ptr: *align(1) const [8]i16 =
                @ptrCast(centroids_t[d2 * num_centroids + ci ..][0..8]);
            const cent_i16: V8i16 = ptr.*;
            const q_i16: V8i16 = @splat(query_i16[d2]);
            const diff_i16 = cent_i16 - q_i16;
            const diff_i32: V8i32 = @intCast(diff_i16);
            const sq: V8i32 = diff_i32 * diff_i32;
            acc_hi +%= @as(V8u32, @bitCast(sq));
        }
        // Soma halves em u64 — sum max 5.6e9 fits in u64 trivialmente.
        const lo_lanes: [8]u32 = acc_lo;
        const hi_lanes: [8]u32 = acc_hi;
        inline for (0..8) |lane| {
            out[ci + lane] = @as(u64, lo_lanes[lane]) + @as(u64, hi_lanes[lane]);
        }
    }
    // Tail (K nao multiplo de 8) — escalar.
    while (ci < num_centroids) : (ci += 1) {
        var s: u64 = 0;
        comptime var d: usize = 0;
        inline while (d < c.DIM) : (d += 1) {
            const q: i32 = query_i16[d];
            const cv: i32 = centroids_t[d * num_centroids + ci];
            const diff = q - cv;
            s += @as(u64, @intCast(diff * diff));
        }
        out[ci] = s;
    }
}

/// Lower bound L2² entre query i16 e bbox axis-aligned do cluster. u64 acc
/// (consistente com centroidDists/scanBlock).
pub fn bboxLowerBound(
    query_i16: *const [c.DIM]i16,
    bb_min: []align(1) const i16, // [c.DIM]
    bb_max: []align(1) const i16,
) u64 {
    var acc: u64 = 0;
    comptime var d: usize = 0;
    inline while (d < c.DIM) : (d += 1) {
        const q: i32 = query_i16[d];
        const lo: i32 = bb_min[d];
        const hi: i32 = bb_max[d];
        const below = lo - q;
        const above = q - hi;
        const delta: i32 = if (below > 0) below else if (above > 0) above else 0;
        acc += @as(u64, @intCast(delta * delta));
    }
    return acc;
}

/// Scan UM bloco de 8 slots (dim-major [DIM][BLOCK_SIZE] i16). Acumula L2² em
/// dois u32 halves (dims 0..7 + 8..13). Variante SEM early-exit, sempre 14 dims.
pub fn scanBlock(
    query_i16: *const [c.DIM]i16,
    block_ptr: [*]align(1) const i16,
    out_dists: *[c.BLOCK_SIZE]u64,
) void {
    var acc_lo: V8u32 = @splat(0);
    comptime var d: usize = 0;
    inline while (d < 8) : (d += 1) {
        accumDim(query_i16, block_ptr, d, &acc_lo);
    }
    var acc_hi: V8u32 = @splat(0);
    comptime var d2: usize = 8;
    inline while (d2 < c.DIM) : (d2 += 1) {
        accumDim(query_i16, block_ptr, d2, &acc_hi);
    }
    const lo_lanes: [8]u32 = acc_lo;
    const hi_lanes: [8]u32 = acc_hi;
    inline for (0..c.BLOCK_SIZE) |lane| {
        out_dists[lane] = @as(u64, lo_lanes[lane]) + @as(u64, hi_lanes[lane]);
    }
}

inline fn accumDim(
    query_i16: *const [c.DIM]i16,
    block_ptr: [*]align(1) const i16,
    comptime d: usize,
    acc: *V8u32,
) void {
    const lane_ptr: *align(1) const [c.BLOCK_SIZE]i16 =
        @ptrCast(block_ptr[d * c.BLOCK_SIZE ..][0..c.BLOCK_SIZE]);
    const lane_i16: V8i16 = lane_ptr.*;
    const q_i16: V8i16 = @splat(query_i16[d]);
    const diff_i16 = lane_i16 - q_i16;
    const diff_i32: V8i32 = @intCast(diff_i16);
    const sq: V8i32 = diff_i32 * diff_i32;
    acc.* +%= @as(V8u32, @bitCast(sq));
}

/// Variante com early-exit: 4 checkpoints (dim 4, 6, 8, 14). Se TODAS as
/// lanes ja excedem `cutoff`, retorna sem completar as 14 dims. Beneficio:
/// blocos com vetores distantes do query encerram em ~30% do trabalho.
/// `cutoff` eh comparada apenas com `acc_lo` ate dim 8; o caller decide se
/// quer acumular `acc_hi` (dims 8..13) — esta funcao SEMPRE acumula todas
/// pra precisao do top5, so corta o trabalho com `out_finished=true`.
///
/// Output:
///   out_dists[lane] = L2² u64 do slot (so valido se nao foi early-exited)
///   retorna `true` se TODAS as lanes podem ser ignoradas (cutoff atingido
///   em todas) — caller pula o insertTop5 do bloco inteiro.
pub fn scanBlockEarlyExit(
    query_i16: *const [c.DIM]i16,
    block_ptr: [*]align(1) const i16,
    cutoff: u64,
    out_dists: *[c.BLOCK_SIZE]u64,
) bool {
    var acc_lo: V8u32 = @splat(0);
    // dim 0..3
    accumDim(query_i16, block_ptr, 0, &acc_lo);
    accumDim(query_i16, block_ptr, 1, &acc_lo);
    accumDim(query_i16, block_ptr, 2, &acc_lo);
    accumDim(query_i16, block_ptr, 3, &acc_lo);
    if (allLanesGE(acc_lo, cutoff)) return true;

    accumDim(query_i16, block_ptr, 4, &acc_lo);
    accumDim(query_i16, block_ptr, 5, &acc_lo);
    if (allLanesGE(acc_lo, cutoff)) return true;

    accumDim(query_i16, block_ptr, 6, &acc_lo);
    accumDim(query_i16, block_ptr, 7, &acc_lo);
    if (allLanesGE(acc_lo, cutoff)) return true;

    // dim 8..13 acumula em acc_hi
    var acc_hi: V8u32 = @splat(0);
    comptime var d2: usize = 8;
    inline while (d2 < c.DIM) : (d2 += 1) {
        accumDim(query_i16, block_ptr, d2, &acc_hi);
    }

    const lo_lanes: [8]u32 = acc_lo;
    const hi_lanes: [8]u32 = acc_hi;
    inline for (0..c.BLOCK_SIZE) |lane| {
        out_dists[lane] = @as(u64, lo_lanes[lane]) + @as(u64, hi_lanes[lane]);
    }
    return false;
}

inline fn allLanesGE(acc: V8u32, cutoff: u64) bool {
    // Se cutoff > u32 max, acc_lo (u32) nunca pode atingir → no early exit
    // (e o trabalho hi serah pequeno comparado ao ganho de skipping todos).
    if (cutoff > std.math.maxInt(u32)) return false;
    const cutoff_u32: u32 = @intCast(cutoff);
    const cutoff_vec: V8u32 = @splat(cutoff_u32);
    const ge = acc >= cutoff_vec;
    return @reduce(.And, ge);
}

test "scanBlock u64 returns expected distances" {
    var q: [c.DIM]i16 = @splat(0);
    q[0] = 100;
    var block: [c.DIM * c.BLOCK_SIZE]i16 align(2) = undefined;
    @memset(&block, 0);
    block[0] = 50;
    block[1] = 150;
    var out: [c.BLOCK_SIZE]u64 = undefined;
    scanBlock(&q, &block, &out);
    try testing.expectEqual(@as(u64, 50 * 50), out[0]);
    try testing.expectEqual(@as(u64, 50 * 50), out[1]);
    try testing.expectEqual(@as(u64, 100 * 100), out[2]);
}

test "bbox lower bound zero when query inside box" {
    const q: [c.DIM]i16 = .{ 100, 200, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const lo: [c.DIM]i16 = .{ 50, 100, -100, -100, -100, -100, -100, -100, -100, -100, -100, -100, -100, -100 };
    const hi: [c.DIM]i16 = .{ 150, 250, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100 };
    const lb = bboxLowerBound(&q, &lo, &hi);
    try testing.expectEqual(@as(u64, 0), lb);
}

test "centroid distance i16 correctness" {
    var query: [c.DIM]i16 = @splat(5000);
    const num = 8;
    var centroids_t: [c.DIM * 8]i16 align(2) = undefined;
    var d: usize = 0;
    while (d < c.DIM) : (d += 1) {
        centroids_t[d * num + 0] = 5000; // same as query → 0
        centroids_t[d * num + 1] = 0;
        centroids_t[d * num + 2] = 10000;
        centroids_t[d * num + 3] = 5000;
        centroids_t[d * num + 4] = 5000;
        centroids_t[d * num + 5] = 5000;
        centroids_t[d * num + 6] = 5000;
        centroids_t[d * num + 7] = 5000;
    }
    var out: [8]u64 = undefined;
    centroidDistsFromQuery(&query, &centroids_t, &out, num);
    try testing.expectEqual(@as(u64, 0), out[0]);
    try testing.expectEqual(@as(u64, 14 * 5000 * 5000), out[1]);
    try testing.expectEqual(@as(u64, 14 * 5000 * 5000), out[2]);
    try testing.expectEqual(@as(u64, 0), out[3]);
}
