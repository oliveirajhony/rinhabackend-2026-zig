const std = @import("std");
const c = @import("constants.zig");

/// Stable LCG PRNG seeded from u64. Deterministic across platforms.
const Rng = struct {
    state: u64,
    fn init(seed: u64) Rng {
        return .{ .state = seed };
    }
    fn next(self: *Rng) u64 {
        self.state = self.state *% 6364136223846793005 +% 1442695040888963407;
        return self.state;
    }
    fn nextRange(self: *Rng, n: u64) u64 {
        return self.next() % n;
    }
    fn nextFloat(self: *Rng) f32 {
        const u = @as(u32, @truncate(self.next() >> 32));
        return @as(f32, @floatFromInt(u)) / @as(f32, @floatFromInt(@as(u32, std.math.maxInt(u32))));
    }
};

fn distSq(point: []const i16, centroid: []const f32) f32 {
    var s: f32 = 0;
    var d: usize = 0;
    while (d < c.DIM) : (d += 1) {
        const diff = @as(f32, @floatFromInt(point[d])) - centroid[d];
        s += diff * diff;
    }
    return s;
}

fn nearest(point: []const i16, centroids: []const f32, k: usize) usize {
    var best: usize = 0;
    var best_d: f32 = std.math.floatMax(f32);
    var ci: usize = 0;
    while (ci < k) : (ci += 1) {
        const d = distSq(point, centroids[ci * c.DIM ..][0..c.DIM]);
        if (d < best_d) {
            best_d = d;
            best = ci;
        }
    }
    return best;
}

/// Returns centroids as a [k * DIM]f32 in centroid-major layout, in i16-scaled
/// units (since the input was i16, sums + means stay in i16 range as f32).
pub fn run(
    allocator: std.mem.Allocator,
    data: []const i16,
    n: usize,
    k: usize,
    sample_size: usize,
    iters: usize,
    seed: u64,
) ![]f32 {
    std.debug.assert(data.len == n * c.DIM);
    var rng = Rng.init(seed);

    const sample_n = @min(sample_size, n);
    const sample = try allocator.alloc(usize, sample_n);
    defer allocator.free(sample);
    for (sample) |*s| s.* = @intCast(rng.nextRange(@intCast(n)));

    const centroids = try allocator.alloc(f32, k * c.DIM);
    @memset(centroids, 0);

    // k-means++ init
    {
        const first = sample[rng.nextRange(@intCast(sample.len))];
        var d: usize = 0;
        while (d < c.DIM) : (d += 1) {
            centroids[d] = @as(f32, @floatFromInt(data[first * c.DIM + d]));
        }
    }
    const min_dists = try allocator.alloc(f32, sample.len);
    defer allocator.free(min_dists);
    @memset(min_dists, std.math.floatMax(f32));

    var ci: usize = 1;
    while (ci < k) : (ci += 1) {
        const prev = centroids[(ci - 1) * c.DIM ..][0..c.DIM];
        for (sample, 0..) |idx, si| {
            const point = data[idx * c.DIM ..][0..c.DIM];
            const d = distSq(point, prev);
            if (d < min_dists[si]) min_dists[si] = d;
        }
        var total: f32 = 0;
        for (min_dists) |d| total += d;
        const pick = rng.nextFloat() * total;
        var acc: f32 = 0;
        var chosen = sample[0];
        for (sample, 0..) |idx, si| {
            acc += min_dists[si];
            if (acc >= pick) {
                chosen = idx;
                break;
            }
        }
        var d: usize = 0;
        while (d < c.DIM) : (d += 1) {
            centroids[ci * c.DIM + d] = @as(f32, @floatFromInt(data[chosen * c.DIM + d]));
        }
    }

    // Lloyd iterations
    const sums = try allocator.alloc(f64, k * c.DIM);
    defer allocator.free(sums);
    const counts = try allocator.alloc(u32, k);
    defer allocator.free(counts);

    var it: usize = 0;
    while (it < iters) : (it += 1) {
        @memset(sums, 0);
        @memset(counts, 0);
        for (sample) |idx| {
            const point = data[idx * c.DIM ..][0..c.DIM];
            const ck = nearest(point, centroids, k);
            counts[ck] += 1;
            var d: usize = 0;
            while (d < c.DIM) : (d += 1) {
                sums[ck * c.DIM + d] += @as(f64, @floatFromInt(point[d]));
            }
        }
        var ck: usize = 0;
        while (ck < k) : (ck += 1) {
            if (counts[ck] > 0) {
                const inv = 1.0 / @as(f64, @floatFromInt(counts[ck]));
                var d: usize = 0;
                while (d < c.DIM) : (d += 1) {
                    centroids[ck * c.DIM + d] = @floatCast(sums[ck * c.DIM + d] * inv);
                }
            }
        }
    }
    return centroids;
}

/// Assign each of the `n` vectors to its nearest centroid.
pub fn assign(
    allocator: std.mem.Allocator,
    data: []const i16,
    n: usize,
    centroids: []const f32,
    k: usize,
) ![]u16 {
    const out = try allocator.alloc(u16, n);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const point = data[i * c.DIM ..][0..c.DIM];
        out[i] = @intCast(nearest(point, centroids, k));
    }
    return out;
}
