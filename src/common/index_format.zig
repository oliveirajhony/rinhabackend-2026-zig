const std = @import("std");
const testing = std.testing;
const c = @import("constants.zig");

pub const MAGIC = [_]u8{ 'R', 'N', 'H', 'A' };
// V2: centroids i16 dim-major SoA (q16 scale). Cabe em L2 do Mac Mini Late
// 2014 (runner oficial) e habilita o kernel inteiro com vpmaddwd via AVX2.
pub const VERSION: u32 = 2;

pub const Header = extern struct {
    magic: [4]u8,
    version: u32,
    num_centroids: u32,
    total_blocks: u32,
    dim: u32,
    block_size: u32,
};

pub const Dataset = struct {
    bytes: []align(8) const u8,
    header: *const Header,
    /// i16 dim-major: [DIM][NUM_CENTROIDS] em escala SCALE=10000.
    centroids: []align(1) const i16,
    bbox_min: []align(1) const i16,
    bbox_max: []align(1) const i16,
    block_offsets: []align(1) const u32,
    blocks: []align(1) const i16,
    labels: []const u8,

    pub fn fromBytes(bytes: []align(8) const u8) !Dataset {
        if (bytes.len < @sizeOf(Header)) return error.TooSmall;
        const hdr: *const Header = @ptrCast(@alignCast(bytes.ptr));
        if (!std.mem.eql(u8, &hdr.magic, &MAGIC)) return error.BadMagic;
        if (hdr.version != VERSION) return error.BadVersion;
        if (hdr.dim != c.DIM) return error.BadDim;
        if (hdr.block_size != c.BLOCK_SIZE) return error.BadBlockSize;

        const k = @as(usize, hdr.num_centroids);
        const tb = @as(usize, hdr.total_blocks);
        const dim = @as(usize, hdr.dim);
        const bs = @as(usize, hdr.block_size);
        var off: usize = @sizeOf(Header);

        const centroids_bytes = k * dim * @sizeOf(i16);
        const centroids = std.mem.bytesAsSlice(i16, bytes[off..][0..centroids_bytes]);
        off += centroids_bytes;

        const bbox_bytes = k * dim * @sizeOf(i16);
        const bbox_min = std.mem.bytesAsSlice(i16, bytes[off..][0..bbox_bytes]);
        off += bbox_bytes;
        const bbox_max = std.mem.bytesAsSlice(i16, bytes[off..][0..bbox_bytes]);
        off += bbox_bytes;

        // u32 quer alinhamento 4. Como centroids+bbox sao multiplos de 2 e DIM=14,
        // K*14*2 sempre da par; com K par, da divisivel por 4 tambem.
        off = std.mem.alignForward(usize, off, @alignOf(u32));
        const offsets_bytes = (k + 1) * @sizeOf(u32);
        const offsets = std.mem.bytesAsSlice(u32, bytes[off..][0..offsets_bytes]);
        off += offsets_bytes;

        const blocks_bytes = tb * dim * bs * @sizeOf(i16);
        const blocks = std.mem.bytesAsSlice(i16, bytes[off..][0..blocks_bytes]);
        off += blocks_bytes;

        const labels = bytes[off..][0 .. tb * bs];

        return .{
            .bytes = bytes,
            .header = hdr,
            .centroids = centroids,
            .bbox_min = bbox_min,
            .bbox_max = bbox_max,
            .block_offsets = offsets,
            .blocks = blocks,
            .labels = labels,
        };
    }
};

pub fn writeHeader(w: anytype, num_centroids: u32, total_blocks: u32) !void {
    const h = Header{
        .magic = MAGIC,
        .version = VERSION,
        .num_centroids = num_centroids,
        .total_blocks = total_blocks,
        .dim = @intCast(c.DIM),
        .block_size = @intCast(c.BLOCK_SIZE),
    };
    try w.writeAll(std.mem.asBytes(&h));
}

test "header size" {
    try testing.expectEqual(@as(usize, 4 + 4 + 4 + 4 + 4 + 4), @sizeOf(Header));
}
