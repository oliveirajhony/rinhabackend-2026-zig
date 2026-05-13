const std = @import("std");
const common = @import("common");
const c = common.constants;
const search = @import("search.zig");

/// Run WARMUP_ITERS synthetic queries against the dataset to populate
/// TLB, L1/L2/L3 cache, and branch predictor BEFORE bind(). Without this
/// the first hundreds of real queries pay page-fault and cache-cold cost,
/// blowing up p99 in the benchmark phase.
///
/// LCG-deterministic so the warmup is reproducible.
pub fn warmup(ds: *const common.index_format.Dataset, ws: *search.Workspace) void {
    var rng: u64 = 0x9e3779b97f4a7c15;
    var i: usize = 0;
    while (i < c.WARMUP_ITERS) : (i += 1) {
        rng = rng *% 6364136223846793005 +% 1442695040888963407;
        var q: [c.DIM]f32 = undefined;
        // Fill 14 dims from rng, all in [0, 1].
        var r = rng;
        comptime var d: usize = 0;
        inline while (d < c.DIM) : (d += 1) {
            r = r *% 6364136223846793005 +% 1442695040888963407;
            const u = @as(u32, @truncate(r >> 32));
            q[d] = @as(f32, @floatFromInt(u)) / 4294967295.0;
        }
        std.mem.doNotOptimizeAway(search.searchFraudCount(ds, &q, ws));
    }
}
