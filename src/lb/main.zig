const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

pub const std_options: std.Options = .{
    .log_level = .info,
};

const MAX_CONNS: usize = 4096;
const BUF_SIZE: usize = 8 * 1024;

/// Per-connection state. Each TCP↔UDS pair owns two Conn slots that
/// point at each other via `peer`. Single-thread event loop reads
/// from a fd and writes to its peer, buffering on partial writes.
const Conn = struct {
    fd: i32 = -1,
    peer: u32 = INVALID, // index into conns[] of the paired side
    pending_n: u16 = 0,
    pending_off: u16 = 0,
    write_blocked: bool = false,
    closed: bool = false,
    buf: [BUF_SIZE]u8 = undefined,

    const INVALID: u32 = std.math.maxInt(u32);

    fn reset(self: *Conn) void {
        self.fd = -1;
        self.peer = INVALID;
        self.pending_n = 0;
        self.pending_off = 0;
        self.write_blocked = false;
        self.closed = false;
    }
};

const State = struct {
    epoll_fd: i32,
    listen_fd: i32,
    conns: []Conn,
    free_stack: []u32,
    free_top: usize,
    backends: []const []const u8,
    rr: usize,

    fn allocConn(self: *State) ?u32 {
        if (self.free_top == 0) return null;
        self.free_top -= 1;
        const idx = self.free_stack[self.free_top];
        self.conns[idx].reset();
        return idx;
    }

    fn freeConn(self: *State, idx: u32) void {
        const c = &self.conns[idx];
        if (c.fd >= 0) {
            _ = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, c.fd, null);
            _ = linux.close(c.fd);
            c.fd = -1;
        }
        self.free_stack[self.free_top] = idx;
        self.free_top += 1;
    }

    fn closePair(self: *State, idx: u32) void {
        const c = &self.conns[idx];
        const peer_idx = c.peer;
        if (peer_idx != Conn.INVALID) {
            self.conns[peer_idx].peer = Conn.INVALID;
            self.freeConn(peer_idx);
        }
        self.freeConn(idx);
    }
};

pub fn main(init: std.process.Init) !void {
    const ally = init.arena.allocator();
    _ = init.io;

    var it = try init.minimal.args.iterateAllocator(ally);
    defer it.deinit();
    _ = it.next();
    const bind_str = it.next() orelse "0.0.0.0:9999";
    const backends_csv = it.next() orelse "/sock/api1.sock,/sock/api2.sock";

    var backend_list = std.ArrayList([]const u8).empty;
    defer backend_list.deinit(ally);
    var sit = std.mem.splitScalar(u8, backends_csv, ',');
    while (sit.next()) |path| {
        const t = std.mem.trim(u8, path, " ");
        if (t.len > 0) try backend_list.append(ally, t);
    }
    if (backend_list.items.len == 0) return error.NoBackends;

    const colon = std.mem.lastIndexOfScalar(u8, bind_str, ':') orelse return error.BadBind;
    const port = try std.fmt.parseInt(u16, bind_str[colon + 1 ..], 10);

    const listen_fd = try openTcpListener(port);
    defer _ = linux.close(listen_fd);

    const epoll_r = linux.epoll_create1(linux.EPOLL.CLOEXEC);
    if (linux.errno(epoll_r) != .SUCCESS) return error.EpollCreateFailed;
    const epoll_fd: i32 = @intCast(@as(isize, @bitCast(epoll_r)));
    defer _ = linux.close(epoll_fd);

    var conns_buf = try ally.alloc(Conn, MAX_CONNS);
    var free_stack = try ally.alloc(u32, MAX_CONNS);
    for (0..MAX_CONNS) |i| {
        conns_buf[i].reset();
        free_stack[MAX_CONNS - 1 - i] = @intCast(i);
    }

    var state = State{
        .epoll_fd = epoll_fd,
        .listen_fd = listen_fd,
        .conns = conns_buf,
        .free_stack = free_stack,
        .free_top = MAX_CONNS,
        .backends = backend_list.items,
        .rr = 0,
    };

    // Register listen_fd with EPOLL_DATA = MAX_CONNS sentinel
    var ev: linux.epoll_event = .{
        .events = linux.EPOLL.IN,
        .data = .{ .u32 = std.math.maxInt(u32) },
    };
    if (linux.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, listen_fd, &ev) != 0) return error.EpollAddListen;

    std.log.info("lb: epoll bind={s} backends={d}", .{ bind_str, state.backends.len });

    var events: [256]linux.epoll_event = undefined;
    while (true) {
        const n_r = linux.epoll_wait(epoll_fd, &events, events.len, -1);
        if (linux.errno(n_r) != .SUCCESS) continue;
        const n: usize = @intCast(@as(isize, @bitCast(n_r)));
        for (events[0..n]) |e| {
            const key = e.data.u32;
            if (key == std.math.maxInt(u32)) {
                handleAccept(&state);
            } else {
                handleConn(&state, key, e.events);
            }
        }
    }
}

fn handleAccept(state: *State) void {
    // Accept loop (edge-triggered would need a loop; level-triggered fires for each)
    while (true) {
        var addr: linux.sockaddr = undefined;
        var addr_len: linux.socklen_t = @sizeOf(linux.sockaddr);
        const r = linux.accept4(state.listen_fd, &addr, &addr_len, linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK);
        if (linux.errno(r) != .SUCCESS) return; // EAGAIN or other; level-triggered will re-fire
        const client_fd: i32 = @intCast(@as(isize, @bitCast(r)));

        var one: c_int = 1;
        _ = linux.setsockopt(client_fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, @ptrCast(&one), @sizeOf(c_int));

        const client_slot = state.allocConn() orelse {
            _ = linux.close(client_fd);
            return;
        };
        const backend_slot = state.allocConn() orelse {
            _ = linux.close(client_fd);
            state.freeConn(client_slot);
            return;
        };

        const backend_path = state.backends[state.rr % state.backends.len];
        state.rr += 1;
        const backend_fd = openUnixClientNonBlocking(backend_path) catch {
            _ = linux.close(client_fd);
            state.freeConn(client_slot);
            state.freeConn(backend_slot);
            continue;
        };

        state.conns[client_slot].fd = client_fd;
        state.conns[client_slot].peer = backend_slot;
        state.conns[backend_slot].fd = backend_fd;
        state.conns[backend_slot].peer = client_slot;

        var c_ev: linux.epoll_event = .{
            .events = linux.EPOLL.IN | linux.EPOLL.RDHUP | linux.EPOLL.ET,
            .data = .{ .u32 = client_slot },
        };
        var b_ev: linux.epoll_event = .{
            .events = linux.EPOLL.IN | linux.EPOLL.RDHUP | linux.EPOLL.ET,
            .data = .{ .u32 = backend_slot },
        };
        _ = linux.epoll_ctl(state.epoll_fd, linux.EPOLL.CTL_ADD, client_fd, &c_ev);
        _ = linux.epoll_ctl(state.epoll_fd, linux.EPOLL.CTL_ADD, backend_fd, &b_ev);
    }
}

fn handleConn(state: *State, idx: u32, events: u32) void {
    const c = &state.conns[idx];
    if (c.fd < 0) return;
    const peer_idx = c.peer;
    if (peer_idx == Conn.INVALID) {
        state.freeConn(idx);
        return;
    }

    if (events & (linux.EPOLL.IN | linux.EPOLL.RDHUP) != 0) {
        switch (forwardFromConn(state, idx)) {
            .ok => {},
            .err => {
                state.closePair(idx);
                return;
            },
            .eof => {
                // src done sending; if peer also closed, tear down
                if (state.conns[peer_idx].closed and state.conns[idx].pending_n == 0) {
                    state.closePair(idx);
                    return;
                }
            },
        }
    }
    if (events & linux.EPOLL.OUT != 0) {
        if (drainPending(state, idx) == .err) {
            state.closePair(idx);
            return;
        }
        // After draining, if peer is closed (no more bytes ever), tear down.
        if (state.conns[idx].pending_n == 0 and state.conns[peer_idx].closed) {
            state.closePair(idx);
            return;
        }
    }
    if (events & (linux.EPOLL.HUP | linux.EPOLL.ERR) != 0) {
        if (state.conns[idx].pending_n == 0) {
            state.closePair(idx);
            return;
        }
    }
}

const FwdResult = enum { ok, err, eof };

fn forwardFromConn(state: *State, src_idx: u32) FwdResult {
    const src = &state.conns[src_idx];
    const dst_idx = src.peer;
    if (src.closed) return .eof;

    while (true) {
        // If destination has pending data, we shouldn't pile more on top — back off.
        if (state.conns[dst_idx].pending_n > 0) return .ok;

        var buf: [BUF_SIZE]u8 = undefined;
        const r = linux.read(src.fd, &buf, buf.len);
        const eno = linux.errno(r);
        if (eno == .AGAIN) return .ok;
        if (eno != .SUCCESS) return .err;
        const n: isize = @bitCast(r);
        if (n <= 0) {
            // EOF: half-close peer's write so its read returns 0 too
            _ = linux.shutdown(state.conns[dst_idx].fd, 1); // SHUT_WR
            src.closed = true;
            return .eof;
        }
        const want: usize = @intCast(n);
        if (writeToPeer(state, dst_idx, buf[0..want]) == .err) return .err;
        if (state.conns[dst_idx].pending_n > 0) return .ok;
    }
}

fn writeToPeer(state: *State, dst_idx: u32, data: []const u8) FwdResult {
    const dst = &state.conns[dst_idx];
    var written: usize = 0;
    while (written < data.len) {
        const w = linux.write(dst.fd, data[written..].ptr, data.len - written);
        const eno = linux.errno(w);
        if (eno == .AGAIN) {
            // Stash remainder, register EPOLLOUT
            const remain = data.len - written;
            if (remain > dst.buf.len) return .err;
            @memcpy(dst.buf[0..remain], data[written..]);
            dst.pending_n = @intCast(remain);
            dst.pending_off = 0;
            var ev: linux.epoll_event = .{
                .events = linux.EPOLL.IN | linux.EPOLL.OUT | linux.EPOLL.RDHUP | linux.EPOLL.ET,
                .data = .{ .u32 = dst_idx },
            };
            _ = linux.epoll_ctl(state.epoll_fd, linux.EPOLL.CTL_MOD, dst.fd, &ev);
            return .ok;
        }
        if (eno != .SUCCESS) return .err;
        const wn: isize = @bitCast(w);
        if (wn <= 0) return .err;
        written += @intCast(wn);
    }
    return .ok;
}

fn drainPending(state: *State, idx: u32) FwdResult {
    const c = &state.conns[idx];
    while (c.pending_n > 0) {
        const w = linux.write(c.fd, c.buf[c.pending_off..].ptr, c.pending_n);
        const eno = linux.errno(w);
        if (eno == .AGAIN) return .ok;
        if (eno != .SUCCESS) return .err;
        const wn: isize = @bitCast(w);
        if (wn <= 0) return .err;
        c.pending_off += @intCast(@as(usize, @intCast(wn)));
        c.pending_n -= @intCast(@as(usize, @intCast(wn)));
    }
    // Done — unregister EPOLLOUT
    var ev: linux.epoll_event = .{
        .events = linux.EPOLL.IN | linux.EPOLL.RDHUP | linux.EPOLL.ET,
        .data = .{ .u32 = idx },
    };
    _ = linux.epoll_ctl(state.epoll_fd, linux.EPOLL.CTL_MOD, c.fd, &ev);
    return .ok;
}

fn openTcpListener(port: u16) !i32 {
    const fd_r = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0);
    if (linux.errno(fd_r) != .SUCCESS) return error.SocketFailed;
    const fd: i32 = @intCast(@as(isize, @bitCast(fd_r)));

    var one: c_int = 1;
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, @ptrCast(&one), @sizeOf(c_int));
    _ = linux.setsockopt(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, @ptrCast(&one), @sizeOf(c_int));

    var addr: linux.sockaddr.in = .{
        .family = linux.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = 0,
        .zero = [_]u8{0} ** 8,
    };
    if (linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in)) != 0) return error.BindFailed;
    if (linux.listen(fd, 4096) != 0) return error.ListenFailed;
    return fd;
}

fn openUnixClientNonBlocking(path: []const u8) !i32 {
    const fd_r = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0);
    if (linux.errno(fd_r) != .SUCCESS) return error.SocketFailed;
    const fd: i32 = @intCast(@as(isize, @bitCast(fd_r)));

    var addr: linux.sockaddr.un = undefined;
    addr.family = linux.AF.UNIX;
    if (path.len + 1 > addr.path.len) return error.PathTooLong;
    @memcpy(addr.path[0..path.len], path);
    addr.path[path.len] = 0;

    const r = linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un));
    const eno = linux.errno(r);
    if (eno == .SUCCESS or eno == .INPROGRESS) return fd;
    _ = linux.close(fd);
    return error.ConnectFailed;
}

comptime {
    if (builtin.os.tag != .linux) @compileError("Linux-only");
}
