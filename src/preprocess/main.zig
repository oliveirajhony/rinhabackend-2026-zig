const std = @import("std");
const common = @import("common");
const c = common.constants;
const quant = common.quant;
const kmeans = common.kmeans;
const index_format = common.index_format;

const flate = std.compress.flate;
const json = std.json;

pub fn main(init: std.process.Init) !void {
    const ally = init.arena.allocator();
    const io = init.io;

    var it = try init.minimal.args.iterateAllocator(ally);
    defer it.deinit();
    _ = it.next();
    const in_path = it.next() orelse "/data/references.json.gz";
    const out_path = it.next() orelse "/index/dataset.bin";

    std.log.info("preprocess: input={s} output={s}", .{ in_path, out_path });

    const n = try countRecords(ally, io, in_path);
    std.log.info("preprocess: counted {d} records", .{n});
    if (n < c.NUM_CENTROIDS) return error.NotEnoughData;

    const data = try ally.alloc(i16, n * c.DIM);
    const labels = try ally.alloc(u8, n);
    @memset(labels, 0);

    try parseAll(ally, io, in_path, n, data, labels);
    std.log.info("preprocess: parsed {d} records into i16 vectors", .{n});

    std.log.info("preprocess: k-means k={d} on {d} sample, {d} iters", .{
        c.NUM_CENTROIDS, c.SAMPLE_SIZE, c.KMEANS_ITERS,
    });
    const centroids_km = try kmeans.run(
        ally,
        data,
        n,
        c.NUM_CENTROIDS,
        c.SAMPLE_SIZE,
        c.KMEANS_ITERS,
        c.KMEANS_SEED,
    );

    std.log.info("preprocess: assigning {d} vectors", .{n});
    const assignments = try kmeans.assign(ally, data, n, centroids_km, c.NUM_CENTROIDS);

    std.log.info("preprocess: building block layout", .{});
    const layout = try buildLayout(ally, data, labels, assignments);

    // Transpose centroids to dim-major SoA i16 [DIM][NUM_CENTROIDS]. kmeans
    // returns centroids em escala i16 (computado sobre data i16 quantizado).
    // Round-to-nearest (~half-up) pra alinhar com a politica de quantizacao
    // que o gerador oficial usa.
    const centroids_t = try ally.alloc(i16, c.DIM * c.NUM_CENTROIDS);
    for (0..c.NUM_CENTROIDS) |ci| {
        for (0..c.DIM) |d| {
            const v = centroids_km[ci * c.DIM + d];
            const r = @round(v);
            const clamped = if (r > 32767.0) 32767.0 else if (r < -32768.0) -32768.0 else r;
            centroids_t[d * c.NUM_CENTROIDS + ci] = @as(i16, @intFromFloat(clamped));
        }
    }

    std.log.info("preprocess: writing {s}", .{out_path});
    const cwd = std.Io.Dir.cwd();
    const out_file = try cwd.createFile(io, out_path, .{ .read = true });
    defer out_file.close(io);

    var write_buf: [256 * 1024]u8 = undefined;
    var fw = out_file.writer(io, &write_buf);
    var w = &fw.interface;

    try index_format.writeHeader(w, @intCast(c.NUM_CENTROIDS), @intCast(layout.total_blocks));
    try w.writeAll(std.mem.sliceAsBytes(centroids_t));
    try w.writeAll(std.mem.sliceAsBytes(layout.bbox_min));
    try w.writeAll(std.mem.sliceAsBytes(layout.bbox_max));
    try w.writeAll(std.mem.sliceAsBytes(layout.block_offsets));
    try w.writeAll(std.mem.sliceAsBytes(layout.blocks));
    try w.writeAll(layout.labels_padded);
    try w.flush();

    std.log.info("preprocess: done — {d} vectors, {d} clusters, {d} blocks", .{
        n, c.NUM_CENTROIDS, layout.total_blocks,
    });
}

const Layout = struct {
    total_blocks: u32,
    bbox_min: []i16,
    bbox_max: []i16,
    block_offsets: []u32,
    blocks: []i16,
    labels_padded: []u8,
};

fn buildLayout(
    ally: std.mem.Allocator,
    data: []const i16,
    labels: []const u8,
    assignments: []const u16,
) !Layout {
    var cluster_counts = try ally.alloc(u32, c.NUM_CENTROIDS);
    @memset(cluster_counts, 0);
    for (assignments) |a| cluster_counts[a] += 1;

    var block_offsets = try ally.alloc(u32, c.NUM_CENTROIDS + 1);
    block_offsets[0] = 0;
    for (0..c.NUM_CENTROIDS) |ci| {
        const nb = (cluster_counts[ci] + @as(u32, @intCast(c.BLOCK_SIZE)) - 1) / @as(u32, @intCast(c.BLOCK_SIZE));
        block_offsets[ci + 1] = block_offsets[ci] + nb;
    }
    const total_blocks = block_offsets[c.NUM_CENTROIDS];
    const padded_n: usize = @as(usize, total_blocks) * c.BLOCK_SIZE;

    var bbox_min = try ally.alloc(i16, c.NUM_CENTROIDS * c.DIM);
    var bbox_max = try ally.alloc(i16, c.NUM_CENTROIDS * c.DIM);
    @memset(bbox_min, std.math.maxInt(i16));
    @memset(bbox_max, std.math.minInt(i16));

    var blocks = try ally.alloc(i16, @as(usize, total_blocks) * c.DIM * c.BLOCK_SIZE);
    @memset(blocks, std.math.maxInt(i16));

    var labels_padded = try ally.alloc(u8, padded_n);
    @memset(labels_padded, 0);

    var cursor = try ally.alloc(u32, c.NUM_CENTROIDS);
    defer ally.free(cursor);
    for (0..c.NUM_CENTROIDS) |ci| cursor[ci] = block_offsets[ci] * @as(u32, @intCast(c.BLOCK_SIZE));

    for (assignments, 0..) |a, i| {
        const cluster: usize = a;
        const dst_slot: usize = cursor[cluster];
        cursor[cluster] += 1;
        const block_id = dst_slot / c.BLOCK_SIZE;
        const slot = dst_slot % c.BLOCK_SIZE;
        labels_padded[block_id * c.BLOCK_SIZE + slot] = labels[i];
        for (0..c.DIM) |d| {
            const v = data[i * c.DIM + d];
            blocks[block_id * c.DIM * c.BLOCK_SIZE + d * c.BLOCK_SIZE + slot] = v;
            const bb = cluster * c.DIM + d;
            if (v < bbox_min[bb]) bbox_min[bb] = v;
            if (v > bbox_max[bb]) bbox_max[bb] = v;
        }
    }

    for (0..c.NUM_CENTROIDS) |ci| {
        if (cluster_counts[ci] == 0) {
            for (0..c.DIM) |d| {
                bbox_min[ci * c.DIM + d] = 0;
                bbox_max[ci * c.DIM + d] = 0;
            }
        }
    }

    return .{
        .total_blocks = total_blocks,
        .bbox_min = bbox_min,
        .bbox_max = bbox_max,
        .block_offsets = block_offsets,
        .blocks = blocks,
        .labels_padded = labels_padded,
    };
}

fn countRecords(ally: std.mem.Allocator, io: std.Io, path: []const u8) !usize {
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);

    var file_buf: [64 * 1024]u8 = undefined;
    var fr = file.reader(io, &file_buf);
    var decompress_buf: [flate.max_window_len]u8 = undefined;
    var dec: flate.Decompress = .init(&fr.interface, .gzip, &decompress_buf);

    var reader = json.Reader.init(ally, &dec.reader);
    defer reader.deinit();

    if (.array_begin != try reader.next()) return error.UnexpectedToken;
    var n: usize = 0;
    while (true) {
        const tt = try reader.peekNextTokenType();
        if (tt == .array_end) {
            _ = try reader.next();
            break;
        }
        try reader.skipValue();
        n += 1;
    }
    return n;
}

fn parseAll(
    ally: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    n: usize,
    data: []i16,
    labels: []u8,
) !void {
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);

    var file_buf: [64 * 1024]u8 = undefined;
    var fr = file.reader(io, &file_buf);
    var decompress_buf: [flate.max_window_len]u8 = undefined;
    var dec: flate.Decompress = .init(&fr.interface, .gzip, &decompress_buf);

    var reader = json.Reader.init(ally, &dec.reader);
    defer reader.deinit();

    if (.array_begin != try reader.next()) return error.UnexpectedToken;

    var idx: usize = 0;
    while (true) {
        const tt = try reader.peekNextTokenType();
        if (tt == .array_end) {
            _ = try reader.next();
            break;
        }
        if (idx >= n) return error.RecordCountMismatch;
        try parseRecord(ally, &reader, idx, data, labels);
        idx += 1;
        if (idx % 200_000 == 0) std.log.info("preprocess: parsed {d}/{d}", .{ idx, n });
    }
    if (idx != n) return error.RecordCountMismatch;
}

fn parseRecord(
    ally: std.mem.Allocator,
    reader: *json.Reader,
    idx: usize,
    data: []i16,
    labels: []u8,
) !void {
    if (.object_begin != try reader.next()) return error.UnexpectedToken;

    var v: [c.DIM]f32 = @splat(0);
    var have_vector = false;
    var have_label = false;
    var label_fraud = false;

    while (true) {
        const tt = try reader.peekNextTokenType();
        if (tt == .object_end) {
            _ = try reader.next();
            break;
        }
        const key_tok = try reader.nextAlloc(ally, .alloc_if_needed);
        const key = switch (key_tok) {
            inline .string, .allocated_string => |s| s,
            else => return error.UnexpectedToken,
        };

        if (std.mem.eql(u8, key, "vector")) {
            if (.array_begin != try reader.next()) return error.UnexpectedToken;
            var i: usize = 0;
            while (true) {
                const vt = try reader.peekNextTokenType();
                if (vt == .array_end) {
                    _ = try reader.next();
                    break;
                }
                const num_tok = try reader.nextAlloc(ally, .alloc_if_needed);
                const slice = switch (num_tok) {
                    inline .number, .allocated_number => |s| s,
                    else => return error.UnexpectedToken,
                };
                if (i >= c.DIM) return error.TooManyFields;
                v[i] = std.fmt.parseFloat(f32, slice) catch return error.BadNumber;
                i += 1;
            }
            if (i != c.DIM) return error.WrongVectorLength;
            have_vector = true;
        } else if (std.mem.eql(u8, key, "label")) {
            const v_tok = try reader.nextAlloc(ally, .alloc_if_needed);
            const lbl = switch (v_tok) {
                inline .string, .allocated_string => |s| s,
                else => return error.UnexpectedToken,
            };
            label_fraud = std.mem.eql(u8, lbl, "fraud");
            have_label = true;
        } else {
            try reader.skipValue();
        }
    }

    if (!have_vector or !have_label) return error.MissingField;
    const q = quant.quantize14(&v);
    @memcpy(data[idx * c.DIM ..][0..c.DIM], &q);
    labels[idx] = if (label_fraud) 1 else 0;
}
