const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

pub const std_options: std.Options = .{
    .log_level = .info,
};

/// LB com fd-pass via SCM_RIGHTS: aceita TCP, manda o client fd pra um backend
/// pelo socket de controle do API (`<sock>.ctrl`), fecha o fd localmente. Zero
/// byte-copy no caminho hot.
///
/// Args: `<bind addr:port> <api1.sock>,<api2.sock>,...`
/// Conecta em `<api*.sock>.ctrl` no startup, conexao persistente por backend.
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

    // Abre conexao ctrl pra cada backend com retry (API pode estar bootando).
    var ctrl_fds = std.ArrayList(i32).empty;
    defer ctrl_fds.deinit(ally);
    for (backend_list.items) |path| {
        const ctrl_path = try std.mem.concatWithSentinel(ally, u8, &.{ path, ".ctrl" }, 0);
        const fd = try connectWithRetry(ctrl_path, 60);
        try ctrl_fds.append(ally, fd);
        std.log.info("lb: ctrl connected -> {s}", .{ctrl_path});
    }

    const colon = std.mem.lastIndexOfScalar(u8, bind_str, ':') orelse return error.BadBind;
    const port = try std.fmt.parseInt(u16, bind_str[colon + 1 ..], 10);
    const listen_fd = try openTcpListener(port);
    defer _ = linux.close(listen_fd);

    std.log.info("lb: bind={s} backends={d} (fd-pass via SCM_RIGHTS)", .{ bind_str, ctrl_fds.items.len });

    var rr: usize = 0;
    while (true) {
        var addr: linux.sockaddr = undefined;
        var addr_len: linux.socklen_t = @sizeOf(linux.sockaddr);
        const r = linux.accept4(listen_fd, &addr, &addr_len, linux.SOCK.CLOEXEC);
        const eno = linux.errno(r);
        if (eno == .INTR or eno == .AGAIN) continue;
        if (eno != .SUCCESS) {
            std.log.warn("lb: accept errno={}", .{eno});
            continue;
        }
        const client_fd: i32 = @intCast(@as(isize, @bitCast(r)));

        // TCP_NODELAY no client (HTTP/1.1 small payloads).
        var one: c_int = 1;
        _ = linux.setsockopt(client_fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, @ptrCast(&one), @sizeOf(c_int));

        const target = ctrl_fds.items[rr % ctrl_fds.items.len];
        rr += 1;

        sendFd(target, client_fd) catch |err| {
            std.log.warn("lb: sendFd failed: {}", .{err});
            _ = linux.close(client_fd);
            continue;
        };
        // Client fd ja foi duplicado pelo kernel pra API; fecha localmente.
        _ = linux.close(client_fd);
    }
}

fn connectWithRetry(path_z: [:0]const u8, max_attempts: u32) !i32 {
    var attempts: u32 = 0;
    while (attempts < max_attempts) : (attempts += 1) {
        const fd_r = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(fd_r) != .SUCCESS) {
            sleepMs(500);
            continue;
        }
        const fd: i32 = @intCast(@as(isize, @bitCast(fd_r)));

        var addr: linux.sockaddr.un = .{ .path = undefined };
        @memset(&addr.path, 0);
        if (path_z.len >= addr.path.len) {
            _ = linux.close(fd);
            return error.PathTooLong;
        }
        @memcpy(addr.path[0..path_z.len], path_z[0..path_z.len]);

        const addrlen: u32 = @intCast(@sizeOf(linux.sa_family_t) + path_z.len + 1);
        const connect_r = linux.connect(fd, @ptrCast(&addr), addrlen);
        if (linux.errno(connect_r) == .SUCCESS) return fd;
        _ = linux.close(fd);
        sleepMs(500);
    }
    return error.ConnectFailed;
}

const cmsg_fd_space = cmsgSpace(@sizeOf(i32));

fn sendFd(ctrl_fd: i32, fd: i32) !void {
    var dummy: [1]u8 = .{0};
    var iov = [1]std.posix.iovec_const{.{ .base = dummy[0..].ptr, .len = dummy.len }};

    var cmsg_buf: [cmsg_fd_space]u8 align(@alignOf(linux.cmsghdr)) = .{0} ** cmsg_fd_space;
    const hdr: *linux.cmsghdr = @ptrCast(@alignCast(&cmsg_buf));
    hdr.* = .{
        .len = cmsgLen(@sizeOf(i32)),
        .level = linux.SOL.SOCKET,
        .type = linux.SCM.RIGHTS,
    };
    const data: *i32 = @ptrCast(@alignCast(cmsgData(hdr)));
    data.* = fd;

    const msg: linux.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = iov[0..].ptr,
        .iovlen = iov.len,
        .control = @ptrCast(&cmsg_buf),
        .controllen = cmsg_buf.len,
        .flags = 0,
    };
    const r = linux.sendmsg(ctrl_fd, &msg, linux.MSG.NOSIGNAL);
    if (linux.errno(r) != .SUCCESS) return error.SendmsgFailed;
}

fn sleepMs(ms: u64) void {
    const req: linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
    var rem: linux.timespec = undefined;
    _ = linux.nanosleep(&req, &rem);
}

inline fn cmsgAlign(len: usize) usize {
    const a = @sizeOf(usize);
    return (len + a - 1) & ~@as(usize, a - 1);
}
inline fn cmsgSpace(len: usize) usize {
    return cmsgAlign(@sizeOf(linux.cmsghdr)) + cmsgAlign(len);
}
inline fn cmsgLen(len: usize) usize {
    return cmsgAlign(@sizeOf(linux.cmsghdr)) + len;
}
inline fn cmsgData(hdr: *linux.cmsghdr) [*]u8 {
    const p: [*]u8 = @ptrCast(hdr);
    return p + cmsgAlign(@sizeOf(linux.cmsghdr));
}

fn openTcpListener(port: u16) !i32 {
    const fd_r = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
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

comptime {
    if (builtin.os.tag != .linux) @compileError("Linux-only");
}
