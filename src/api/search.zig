const std = @import("std");
const common = @import("common");
const c = common.constants;
const simd = common.simd;
const index_format = common.index_format;

const Top5Entry = struct {
    dist: u64,
    label: u8,
};

pub const Workspace = struct {
    /// L2² u64 por centroid; usado pra ranquear FULL candidatos.
    centroid_dists: [c.NUM_CENTROIDS]u64 = undefined,

    pub fn init() Workspace {
        return .{};
    }
};

/// Quantiza query f32 [0,1] / -1 (sentinel) para i16 [0, SCALE] / -SCALE.
fn quantizeQuery(query_f32: *const [c.DIM]f32) [c.DIM]i16 {
    var qi: [c.DIM]i16 = undefined;
    comptime var d: usize = 0;
    inline while (d < c.DIM) : (d += 1) {
        const v = query_f32[d];
        if (v < 0.0) {
            qi[d] = c.SENTINEL_I16;
        } else {
            const scaled = v * c.SCALE;
            qi[d] = @as(i16, @intFromFloat(@round(scaled)));
        }
    }
    return qi;
}

/// IVF 2-tier + adaptive fallback {ADAPTIVE_MIN..ADAPTIVE_MAX}. Kernel inteiro
/// i16 → u32 halves → u64 (vide simd.zig).
pub fn searchFraudCount(
    ds: *const index_format.Dataset,
    query_f32: *const [c.DIM]f32,
    ws: *Workspace,
) u8 {
    const k = ds.header.num_centroids;
    const qi = quantizeQuery(query_f32);

    // 1) Distancias centroid (u64 acc)
    simd.centroidDistsFromQuery(&qi, ds.centroids, &ws.centroid_dists, k);

    // 2) Top-FULL_NPROBE candidatos (insertion sort em buffer estatico).
    var probes: [c.FULL_NPROBE]u32 = .{std.math.maxInt(u32)} ** c.FULL_NPROBE;
    var probe_dists: [c.FULL_NPROBE]u64 = .{std.math.maxInt(u64)} ** c.FULL_NPROBE;
    var i: u32 = 0;
    while (i < k) : (i += 1) {
        const d = ws.centroid_dists[i];
        if (d < probe_dists[c.FULL_NPROBE - 1]) {
            var j: usize = c.FULL_NPROBE - 1;
            while (j > 0 and probe_dists[j - 1] > d) : (j -= 1) {
                probe_dists[j] = probe_dists[j - 1];
                probes[j] = probes[j - 1];
            }
            probe_dists[j] = d;
            probes[j] = i;
        }
    }

    // 3) Fast tier: escaneia primeiros FAST_NPROBE. Pula bbox prune em pi=0
    //    (sempre eh o nearest, nunca queremos pular).
    var top5 = [_]Top5Entry{.{ .dist = std.math.maxInt(u64), .label = 0 }} ** c.TOP_K;

    var pi: usize = 0;
    while (pi < c.FAST_NPROBE) : (pi += 1) {
        const pc = probes[pi];
        if (pc == std.math.maxInt(u32)) continue;
        if (pi != 0) {
            const lb = bboxLb(ds, &qi, pc);
            if (lb >= top5[c.TOP_K - 1].dist) continue;
        }
        scanCluster(ds, &qi, pc, &top5);
    }

    var fraud_count = countFrauds(&top5);

    // 4) Adaptive fallback: refina se borderline.
    if (fraud_count >= c.ADAPTIVE_MIN and fraud_count <= c.ADAPTIVE_MAX) {
        while (pi < c.FULL_NPROBE) : (pi += 1) {
            const pc = probes[pi];
            if (pc == std.math.maxInt(u32)) continue;
            const lb = bboxLb(ds, &qi, pc);
            if (lb >= top5[c.TOP_K - 1].dist) continue;
            scanCluster(ds, &qi, pc, &top5);
        }
        fraud_count = countFrauds(&top5);
    }

    return fraud_count;
}

inline fn bboxLb(ds: *const index_format.Dataset, qi: *const [c.DIM]i16, cluster_idx: u32) u64 {
    const bb_min = ds.bbox_min[cluster_idx * c.DIM ..][0..c.DIM];
    const bb_max = ds.bbox_max[cluster_idx * c.DIM ..][0..c.DIM];
    return simd.bboxLowerBound(qi, bb_min, bb_max);
}

fn countFrauds(top5: *const [c.TOP_K]Top5Entry) u8 {
    var f: u8 = 0;
    for (top5) |e| f += e.label;
    return f;
}

fn scanCluster(
    ds: *const index_format.Dataset,
    query_i16: *const [c.DIM]i16,
    cluster_idx: u32,
    top5: *[c.TOP_K]Top5Entry,
) void {
    const block_start = ds.block_offsets[cluster_idx];
    const block_end = ds.block_offsets[cluster_idx + 1];

    var bi: u32 = block_start;
    while (bi < block_end) : (bi += 1) {
        const block_ptr = ds.blocks.ptr + @as(usize, bi) * c.DIM * c.BLOCK_SIZE;
        const labels_ptr = ds.labels.ptr + @as(usize, bi) * c.BLOCK_SIZE;
        var dists: [c.BLOCK_SIZE]u64 = undefined;
        const cutoff = top5[c.TOP_K - 1].dist;
        const skipped = simd.scanBlockEarlyExit(query_i16, block_ptr, cutoff, &dists);
        if (skipped) continue;
        comptime var slot: usize = 0;
        inline while (slot < c.BLOCK_SIZE) : (slot += 1) {
            const d = dists[slot];
            if (d < top5[c.TOP_K - 1].dist) {
                insertTop5(top5, .{ .dist = d, .label = labels_ptr[slot] });
            }
        }
    }
}

fn insertTop5(top5: *[c.TOP_K]Top5Entry, e: Top5Entry) void {
    var j: usize = c.TOP_K - 1;
    while (j > 0 and top5[j - 1].dist > e.dist) : (j -= 1) {
        top5[j] = top5[j - 1];
    }
    top5[j] = e;
}
