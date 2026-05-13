const std = @import("std");

/// 6 respostas HTTP/1.1 estáticas — uma para cada valor possível de
/// `fraud_count` (0..5). `approved = fraud_count < 3`, `fraud_score = fraud_count * 0.2`.
/// Cada resposta é uma única slice estática para 1 send() / writev().
const body_bucket = [_][]const u8{
    "{\"approved\":true,\"fraud_score\":0.0}",
    "{\"approved\":true,\"fraud_score\":0.2}",
    "{\"approved\":true,\"fraud_score\":0.4}",
    "{\"approved\":false,\"fraud_score\":0.6}",
    "{\"approved\":false,\"fraud_score\":0.8}",
    "{\"approved\":false,\"fraud_score\":1.0}",
};

const fraud_keep = blk: {
    var out: [6][]const u8 = undefined;
    for (body_bucket, 0..) |body, i| {
        const cl_str = std.fmt.comptimePrint("{d}", .{body.len});
        out[i] = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " ++ cl_str ++ "\r\n\r\n" ++ body;
    }
    break :blk out;
};

const fraud_close = blk: {
    var out: [6][]const u8 = undefined;
    for (body_bucket, 0..) |body, i| {
        const cl_str = std.fmt.comptimePrint("{d}", .{body.len});
        out[i] = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " ++ cl_str ++ "\r\nConnection: close\r\n\r\n" ++ body;
    }
    break :blk out;
};

pub const ready: []const u8 = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n";
pub const ready_close: []const u8 = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
pub const bad_request_close: []const u8 = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
pub const not_found_close: []const u8 = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
pub const too_large_close: []const u8 = "HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
pub const internal_close: []const u8 = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";

pub fn fraudScore(fraud_count: u8, keep_alive: bool) []const u8 {
    const idx = if (fraud_count > 5) 5 else fraud_count;
    return if (keep_alive) fraud_keep[idx] else fraud_close[idx];
}

test "fraudScore returns increasing-length headers" {
    const testing = std.testing;
    const r0 = fraudScore(0, true);
    const r5 = fraudScore(5, true);
    try testing.expect(std.mem.indexOf(u8, r0, "\"fraud_score\":0.0") != null);
    try testing.expect(std.mem.indexOf(u8, r5, "\"fraud_score\":1.0") != null);
    try testing.expect(std.mem.indexOf(u8, r0, "Connection: close") == null);
    const r0c = fraudScore(0, false);
    try testing.expect(std.mem.indexOf(u8, r0c, "Connection: close") != null);
}
