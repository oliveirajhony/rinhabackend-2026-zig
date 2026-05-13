const std = @import("std");
const builtin = @import("builtin");
const common = @import("common");
const responses = @import("responses.zig");
const parser = @import("parser.zig");
const search = @import("search.zig");
const warmup_mod = @import("warmup.zig");
const c = common.constants;
const linux = std.os.linux;
const IoUring = linux.IoUring;

pub const std_options: std.Options = .{
    .log_level = .info,
};

const MAX_REQUEST_BYTES: usize = 4096;
const MAX_CONNS_PER_WORKER: usize = 512;
const RING_ENTRIES: u16 = 2048;
const NUM_WORKERS: usize = 4;

const Op = enum(u8) { accept = 0, read = 1, write = 2, close = 3 };

inline fn encodeUd(op: Op, idx: u32) u64 {
    return (@as(u64, @intFromEnum(op)) << 32) | @as(u64, idx);
}
inline fn decodeOp(ud: u64) Op {
    return @enumFromInt(@as(u8, @truncate(ud >> 32)));
}
inline fn decodeIdx(ud: u64) u32 {
    return @as(u32, @truncate(ud));
}

const Conn = struct {
    fd: i32 = -1,
    fill: u32 = 0,
    closing: bool = false,
    buf: [MAX_REQUEST_BYTES]u8 = undefined,
};

const Worker = struct {
    ring: IoUring,
    listen_fd: i32,
    ds: *const common.index_format.Dataset,
    ws: search.Workspace,
    conns: [MAX_CONNS_PER_WORKER]Conn = undefined,
    free_stack: [MAX_CONNS_PER_WORKER]u32 = undefined,
    free_top: usize = MAX_CONNS_PER_WORKER,
    id: usize = 0,

    fn alloc(self: *Worker) ?u32 {
        if (self.free_top == 0) return null;
        self.free_top -= 1;
        const idx = self.free_stack[self.free_top];
        self.conns[idx] = .{};
        return idx;
    }
    fn release(self: *Worker, idx: u32) void {
        self.free_stack[self.free_top] = idx;
        self.free_top += 1;
    }
};

pub fn main(init: std.process.Init) !void {
    const ally = init.arena.allocator();
    const io = init.io;

    var it = try init.minimal.args.iterateAllocator(ally);
    defer it.deinit();
    _ = it.next();
    const sock_path = it.next() orelse "/sock/api.sock";
    const dataset_path = it.next() orelse "/dataset.bin";

    std.log.info("api: socket={s} dataset={s}", .{ sock_path, dataset_path });

    const cwd = std.Io.Dir.cwd();
    const ds_file = try cwd.openFile(io, dataset_path, .{ .mode = .read_only });
    defer ds_file.close(io);
    const total = try ds_file.length(io);

    var mm = try std.Io.File.MemoryMap.create(io, ds_file, .{
        .len = @intCast(total),
        .protection = .{ .read = true },
        .undefined_contents = false,
        .populate = true,
        .offset = 0,
    });
    defer mm.destroy(io);

    const aligned: []align(8) const u8 = @alignCast(mm.memory);
    const ds = try common.index_format.Dataset.fromBytes(aligned);
    std.log.info("api: dataset loaded — k={d} blocks={d}", .{ ds.header.num_centroids, ds.header.total_blocks });

    var warm_ws = search.Workspace.init();
    warmup_mod.warmup(&ds, &warm_ws);
    std.log.info("api: warmup ({d} iters) done", .{c.WARMUP_ITERS});

    cwd.deleteFile(io, sock_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const ua = try std.Io.net.UnixAddress.init(sock_path);
    var server = try ua.listen(io, .{ .kernel_backlog = 4096 });
    defer server.deinit(io);

    const sock_z = try ally.dupeZ(u8, sock_path);
    if (std.c.chmod(sock_z.ptr, 0o666) != 0) std.log.warn("chmod failed on {s}", .{sock_path});

    std.log.info("api: io_uring x{d} workers listening on {s}", .{ NUM_WORKERS, sock_path });

    const c_alloc = std.heap.c_allocator;
    const workers = try c_alloc.alloc(Worker, NUM_WORKERS);
    defer c_alloc.free(workers);

    for (workers, 0..) |*w, i| {
        w.* = .{
            .ring = try IoUring.init(RING_ENTRIES, 0),
            .listen_fd = server.socket.handle,
            .ds = &ds,
            .ws = search.Workspace.init(),
            .id = i,
        };
        for (&w.conns, 0..) |*conn, ci| {
            conn.* = .{};
            w.free_stack[MAX_CONNS_PER_WORKER - 1 - ci] = @intCast(ci);
        }
    }

    const threads = try c_alloc.alloc(std.Thread, NUM_WORKERS - 1);
    defer c_alloc.free(threads);
    for (threads, 1..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, workerMain, .{&workers[i]});
    }
    workerMain(&workers[0]);
    for (threads) |t| t.join();
}

fn workerMain(w: *Worker) void {
    // Each worker submits its own accept_multishot on the shared listen_fd.
    // Kernel distributes accepts across rings.
    _ = w.ring.accept_multishot(encodeUd(.accept, 0), w.listen_fd, null, null, 0) catch |err| {
        std.log.err("worker {d}: accept_multishot init: {}", .{ w.id, err });
        return;
    };

    var cqes: [128]linux.io_uring_cqe = undefined;
    while (true) {
        _ = w.ring.submit_and_wait(1) catch continue;
        const n = w.ring.copy_cqes(&cqes, 0) catch continue;
        for (cqes[0..n]) |cqe| handleCqe(w, cqe);
    }
}

fn handleCqe(w: *Worker, cqe: linux.io_uring_cqe) void {
    const op = decodeOp(cqe.user_data);
    const idx = decodeIdx(cqe.user_data);
    switch (op) {
        .accept => handleAccept(w, cqe),
        .read => handleRead(w, idx, cqe),
        .write => handleWrite(w, idx, cqe),
        .close => w.release(idx),
    }
}

fn handleAccept(w: *Worker, cqe: linux.io_uring_cqe) void {
    if (cqe.res < 0) {
        _ = w.ring.accept_multishot(encodeUd(.accept, 0), w.listen_fd, null, null, 0) catch {};
        return;
    }
    const fd = cqe.res;
    if ((cqe.flags & linux.IORING_CQE_F_MORE) == 0) {
        _ = w.ring.accept_multishot(encodeUd(.accept, 0), w.listen_fd, null, null, 0) catch {};
    }

    const conn_idx = w.alloc() orelse {
        _ = w.ring.close(encodeUd(.close, 0), fd) catch {};
        return;
    };
    const conn = &w.conns[conn_idx];
    conn.fd = fd;
    conn.fill = 0;
    conn.closing = false;
    submitRead(w, conn_idx);
}

fn submitRead(w: *Worker, idx: u32) void {
    const conn = &w.conns[idx];
    const remaining = conn.buf[conn.fill..];
    if (remaining.len == 0) {
        closeConn(w, idx, responses.too_large_close);
        return;
    }
    _ = w.ring.read(encodeUd(.read, idx), conn.fd, .{ .buffer = remaining }, 0) catch {
        closeConn(w, idx, null);
    };
}

fn submitWrite(w: *Worker, idx: u32, data: []const u8) void {
    _ = w.ring.write(encodeUd(.write, idx), w.conns[idx].fd, data, 0) catch {
        closeConn(w, idx, null);
    };
}

fn handleRead(w: *Worker, idx: u32, cqe: linux.io_uring_cqe) void {
    if (cqe.res <= 0) {
        closeConn(w, idx, null);
        return;
    }
    const conn = &w.conns[idx];
    conn.fill += @intCast(cqe.res);

    const pr = parser.parseHttp(conn.buf[0..conn.fill]);
    switch (pr.status) {
        .incomplete => submitRead(w, idx),
        .bad => closeConn(w, idx, responses.bad_request_close),
        .ok => {
            const req = pr.request;
            const resp = computeResponse(w, req);
            const remaining = conn.fill - @as(u32, @intCast(req.total_len));
            if (remaining > 0) std.mem.copyForwards(u8, conn.buf[0..remaining], conn.buf[req.total_len .. conn.fill]);
            conn.fill = remaining;
            conn.closing = !req.keep_alive;
            submitWrite(w, idx, resp);
        },
    }
}

fn computeResponse(w: *Worker, req: parser.ParsedRequest) []const u8 {
    return switch (req.endpoint) {
        .ready => if (req.keep_alive) responses.ready else responses.ready_close,
        .not_found => responses.not_found_close,
        .fraud_score => blk: {
            const q = parser.parseToVector(req.body) orelse break :blk responses.bad_request_close;
            const fraud_count = search.searchFraudCount(w.ds, &q, &w.ws);
            break :blk responses.fraudScore(fraud_count, req.keep_alive);
        },
    };
}

fn handleWrite(w: *Worker, idx: u32, cqe: linux.io_uring_cqe) void {
    if (cqe.res <= 0) {
        closeConn(w, idx, null);
        return;
    }
    const conn = &w.conns[idx];
    if (conn.closing) {
        closeConn(w, idx, null);
        return;
    }
    if (conn.fill > 0) {
        const pr = parser.parseHttp(conn.buf[0..conn.fill]);
        switch (pr.status) {
            .ok => {
                const req = pr.request;
                const resp = computeResponse(w, req);
                const remaining = conn.fill - @as(u32, @intCast(req.total_len));
                if (remaining > 0) std.mem.copyForwards(u8, conn.buf[0..remaining], conn.buf[req.total_len .. conn.fill]);
                conn.fill = remaining;
                conn.closing = !req.keep_alive;
                submitWrite(w, idx, resp);
                return;
            },
            .incomplete => {
                submitRead(w, idx);
                return;
            },
            .bad => {
                closeConn(w, idx, responses.bad_request_close);
                return;
            },
        }
    }
    submitRead(w, idx);
}

fn closeConn(w: *Worker, idx: u32, last_write: ?[]const u8) void {
    const conn = &w.conns[idx];
    if (last_write) |data| {
        _ = w.ring.write(encodeUd(.close, idx), conn.fd, data, 0) catch {};
    } else {
        _ = w.ring.close(encodeUd(.close, idx), conn.fd) catch {
            w.release(idx);
        };
    }
}

comptime {
    if (builtin.os.tag != .linux) @compileError("Linux-only: requires UDS + io_uring");
}
