const std = @import("std");
const builtin = @import("builtin");

const linux = std.os.linux;

pub const cmsg_fd_space = cmsgSpace(@sizeOf(i32));

pub fn openUnixListener(path_z: [:0]const u8) !i32 {
    if (builtin.os.tag != .linux) return error.Unsupported;

    const unlink_r = linux.unlink(path_z.ptr);
    switch (linux.errno(unlink_r)) {
        .SUCCESS, .NOENT => {},
        else => {},
    }

    const fd_r = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(fd_r) != .SUCCESS) return error.SocketFailed;
    const fd: i32 = @intCast(@as(isize, @bitCast(fd_r)));
    errdefer _ = linux.close(fd);

    var addr = try unixAddr(path_z[0..path_z.len]);
    const sa: *const linux.sockaddr = @ptrCast(&addr);
    const addrlen: u32 = @intCast(@sizeOf(linux.sa_family_t) + path_z.len + 1);
    const bind_r = linux.bind(fd, sa, addrlen);
    if (linux.errno(bind_r) != .SUCCESS) return error.BindFailed;

    const listen_r = linux.listen(fd, 1024);
    if (linux.errno(listen_r) != .SUCCESS) return error.ListenFailed;
    return fd;
}

pub fn connectUnix(path_z: [:0]const u8) !i32 {
    if (builtin.os.tag != .linux) return error.Unsupported;

    const fd_r = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(fd_r) != .SUCCESS) return error.SocketFailed;
    const fd: i32 = @intCast(@as(isize, @bitCast(fd_r)));
    errdefer _ = linux.close(fd);

    var addr = try unixAddr(path_z[0..path_z.len]);
    const sa: *const linux.sockaddr = @ptrCast(&addr);
    const addrlen: u32 = @intCast(@sizeOf(linux.sa_family_t) + path_z.len + 1);
    const connect_r = linux.connect(fd, sa, addrlen);
    if (linux.errno(connect_r) != .SUCCESS) return error.ConnectFailed;
    return fd;
}

pub fn sendFd(ctrl_fd: i32, fd: i32) !void {
    if (builtin.os.tag != .linux) return error.Unsupported;

    var dummy: [1]u8 = .{0};
    var iov = [1]std.posix.iovec_const{.{
        .base = dummy[0..].ptr,
        .len = dummy.len,
    }};

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
    const send_r = linux.sendmsg(ctrl_fd, &msg, linux.MSG.NOSIGNAL);
    if (linux.errno(send_r) != .SUCCESS) return error.SendmsgFailed;
}

/// Recebe um FD via SCM_RIGHTS. Bloqueante (uso na control thread).
/// Retorna null em EOF ou erro.
pub fn recvFd(sock_fd: i32) ?i32 {
    if (builtin.os.tag != .linux) return null;

    var dummy: [1]u8 = .{0};
    var iov = [1]std.posix.iovec{.{
        .base = dummy[0..].ptr,
        .len = dummy.len,
    }};

    var cmsg_buf: [cmsg_fd_space]u8 align(@alignOf(linux.cmsghdr)) = .{0} ** cmsg_fd_space;
    var msg: linux.msghdr = .{
        .name = null,
        .namelen = 0,
        .iov = iov[0..].ptr,
        .iovlen = iov.len,
        .control = @ptrCast(&cmsg_buf),
        .controllen = cmsg_buf.len,
        .flags = 0,
    };

    const recv_r = linux.recvmsg(sock_fd, &msg, linux.MSG.CMSG_CLOEXEC);
    if (linux.errno(recv_r) != .SUCCESS or recv_r == 0) return null;
    if (msg.controllen < @sizeOf(linux.cmsghdr)) return null;

    const hdr: *const linux.cmsghdr = @ptrCast(@alignCast(&cmsg_buf));
    if (hdr.level != linux.SOL.SOCKET or hdr.type != linux.SCM.RIGHTS) return null;
    if (hdr.len < cmsgLen(@sizeOf(i32))) return null;

    const data: *const i32 = @ptrCast(@alignCast(cmsgDataConst(hdr)));
    return data.*;
}

pub fn notifyEvent(event_fd: i32) void {
    if (builtin.os.tag != .linux) return;
    var one: u64 = 1;
    const bytes = std.mem.asBytes(&one);
    _ = linux.write(event_fd, bytes.ptr, bytes.len);
}

pub fn closeFd(fd: i32) void {
    if (builtin.os.tag == .linux) _ = linux.close(fd);
}

fn unixAddr(path: []const u8) !linux.sockaddr.un {
    if (path.len >= 108) return error.PathTooLong;
    var addr: linux.sockaddr.un = .{ .path = undefined };
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..path.len], path);
    return addr;
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

inline fn cmsgDataConst(hdr: *const linux.cmsghdr) [*]const u8 {
    const p: [*]const u8 = @ptrCast(hdr);
    return p + cmsgAlign(@sizeOf(linux.cmsghdr));
}
