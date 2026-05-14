const std = @import("std");
const builtin = @import("builtin");
const common = @import("common");
const responses = @import("responses.zig");
const parser = @import("parser.zig");
const search = @import("search.zig");
const warmup_mod = @import("warmup.zig");
const fdpass = @import("fdpass.zig");
const c = common.constants;
const linux = std.os.linux;
const IoUring = linux.IoUring;

pub const std_options: std.Options = .{
    .log_level = .info,
};

const MAX_REQUEST_BYTES: usize = 4096;
const MAX_CONNS: usize = 1024;
const RING_ENTRIES: u16 = 2048;
const FD_QUEUE_SIZE: usize = MAX_CONNS * 2;

const Op = enum(u8) { accept = 0, read = 1, write = 2, close = 3, eventfd_read = 4 };

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

/// SPSC queue: control thread pushes, worker thread pops. Spinlock simples
/// porque os push/pop sao curtissimos.
const FdQueue = struct {
    lock_flag: std.atomic.Value(bool) = .init(false),
    fds: [FD_QUEUE_SIZE]i32 = undefined,
    len: usize = 0,

    fn lock(self: *FdQueue) void {
        while (self.lock_flag.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn unlock(self: *FdQueue) void {
        self.lock_flag.store(false, .release);
    }

    fn push(self: *FdQueue, fd: i32) bool {
        self.lock();
        defer self.unlock();
        if (self.len >= self.fds.len) return false;
        self.fds[self.len] = fd;
        self.len += 1;
        return true;
    }

    fn drain(self: *FdQueue, out: []i32) usize {
        self.lock();
        defer self.unlock();
        const n = @min(self.len, out.len);
        @memcpy(out[0..n], self.fds[self.len - n .. self.len]);
        self.len -= n;
        return n;
    }
};

const Worker = struct {
    ring: IoUring,
    listen_fd: i32,
    event_fd: i32,
    queue: *FdQueue,
    ds: *const common.index_format.Dataset,
    ws: search.Workspace,
    conns: [MAX_CONNS]Conn = undefined,
    free_stack: [MAX_CONNS]u32 = undefined,
    free_top: usize = MAX_CONNS,
    event_buf: [8]u8 = undefined,

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

const ControlCtx = struct {
    listen_fd: i32,
    event_fd: i32,
    queue: *FdQueue,
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

    // Data socket (fallback / smoke test). LB com fd-pass nao usa.
    cwd.deleteFile(io, sock_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const ua = try std.Io.net.UnixAddress.init(sock_path);
    var server = try ua.listen(io, .{ .kernel_backlog = 4096 });
    defer server.deinit(io);

    const sock_z = try ally.dupeZ(u8, sock_path);
    if (std.c.chmod(sock_z.ptr, 0o666) != 0) std.log.warn("chmod failed on {s}", .{sock_path});

    // Control socket: LB conecta uma vez, manda FDs via SCM_RIGHTS em loop.
    const ctrl_path_z = try std.mem.concatWithSentinel(ally, u8, &.{ sock_path, ".ctrl" }, 0);
    const ctrl_fd = try fdpass.openUnixListener(ctrl_path_z);
    defer fdpass.closeFd(ctrl_fd);
    if (std.c.chmod(ctrl_path_z.ptr, 0o666) != 0) std.log.warn("chmod failed on {s}", .{ctrl_path_z});
    std.log.info("api: ctrl listener on {s}", .{ctrl_path_z});

    // eventfd para a control thread acordar o worker io_uring.
    const event_r = linux.eventfd(0, linux.EFD.CLOEXEC);
    if (linux.errno(event_r) != .SUCCESS) return error.EventFdFailed;
    const event_fd: i32 = @intCast(@as(isize, @bitCast(event_r)));
    defer fdpass.closeFd(event_fd);

    const c_alloc = std.heap.c_allocator;
    const queue = try c_alloc.create(FdQueue);
    defer c_alloc.destroy(queue);
    queue.* = FdQueue{};

    const ctrl_ctx = try ally.create(ControlCtx);
    ctrl_ctx.* = .{
        .listen_fd = ctrl_fd,
        .event_fd = event_fd,
        .queue = queue,
    };
    const ctrl_thread = try std.Thread.spawn(.{}, controlThread, .{ctrl_ctx});
    ctrl_thread.detach();

    var worker = Worker{
        .ring = try IoUring.init(RING_ENTRIES, 0),
        .listen_fd = server.socket.handle,
        .event_fd = event_fd,
        .queue = queue,
        .ds = &ds,
        .ws = search.Workspace.init(),
    };
    for (&worker.conns, 0..) |*conn, ci| {
        conn.* = .{};
        worker.free_stack[MAX_CONNS - 1 - ci] = @intCast(ci);
    }

    workerMain(&worker);
}

fn controlThread(ctx: *ControlCtx) void {
    while (true) {
        const accept_r = linux.accept4(ctx.listen_fd, null, null, linux.SOCK.CLOEXEC);
        if (linux.errno(accept_r) != .SUCCESS) continue;
        const conn_fd: i32 = @intCast(@as(isize, @bitCast(accept_r)));
        defer fdpass.closeFd(conn_fd);

        while (fdpass.recvFd(conn_fd)) |fd| {
            if (ctx.queue.push(fd)) {
                fdpass.notifyEvent(ctx.event_fd);
            } else {
                // Fila cheia: drop a conexao (degradacao graceful sob pico).
                fdpass.closeFd(fd);
            }
        }
    }
}

fn workerMain(w: *Worker) void {
    // accept_multishot no data socket (fallback / smoke).
    _ = w.ring.accept_multishot(encodeUd(.accept, 0), w.listen_fd, null, null, 0) catch |err| {
        std.log.err("worker: accept_multishot init: {}", .{err});
        return;
    };
    // read no eventfd para acordar quando a control thread sinalizar.
    submitEventfdRead(w);

    var cqes: [128]linux.io_uring_cqe = undefined;
    while (true) {
        _ = w.ring.submit_and_wait(1) catch continue;
        const n = w.ring.copy_cqes(&cqes, 0) catch continue;
        for (cqes[0..n]) |cqe| handleCqe(w, cqe);
    }
}

fn submitEventfdRead(w: *Worker) void {
    _ = w.ring.read(encodeUd(.eventfd_read, 0), w.event_fd, .{ .buffer = &w.event_buf }, 0) catch {};
}

fn handleCqe(w: *Worker, cqe: linux.io_uring_cqe) void {
    const op = decodeOp(cqe.user_data);
    const idx = decodeIdx(cqe.user_data);
    switch (op) {
        .accept => handleAccept(w, cqe),
        .read => handleRead(w, idx, cqe),
        .write => handleWrite(w, idx, cqe),
        .close => w.release(idx),
        .eventfd_read => handleEventfdRead(w, cqe),
    }
}

fn handleEventfdRead(w: *Worker, cqe: linux.io_uring_cqe) void {
    // Re-arma o eventfd read antes de drenar (evita perder notificacoes durante o drain).
    submitEventfdRead(w);
    if (cqe.res < 0) return;

    // Drena ate 64 FDs por wake-up (limita stalls do worker loop).
    var batch: [64]i32 = undefined;
    while (true) {
        const n = w.queue.drain(&batch);
        if (n == 0) return;
        for (batch[0..n]) |fd| acceptFromQueue(w, fd);
    }
}

fn acceptFromQueue(w: *Worker, fd: i32) void {
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

fn handleAccept(w: *Worker, cqe: linux.io_uring_cqe) void {
    if (cqe.res < 0) {
        _ = w.ring.accept_multishot(encodeUd(.accept, 0), w.listen_fd, null, null, 0) catch {};
        return;
    }
    const fd = cqe.res;
    if ((cqe.flags & linux.IORING_CQE_F_MORE) == 0) {
        _ = w.ring.accept_multishot(encodeUd(.accept, 0), w.listen_fd, null, null, 0) catch {};
    }
    acceptFromQueue(w, fd);
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
