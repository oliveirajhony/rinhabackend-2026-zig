const std = @import("std");
const testing = std.testing;
const common = @import("common");
const c = common.constants;
const mcc = common.mcc;

pub const SENTINEL_F32: f32 = -1.0;

pub const Endpoint = enum { ready, fraud_score, not_found };

pub const ParsedRequest = struct {
    endpoint: Endpoint,
    body: []const u8,
    total_len: usize, // bytes consumidos da stream (headers + body)
    keep_alive: bool,
};

pub const ParseStatus = enum { incomplete, ok, bad };

pub const ParseResult = struct {
    status: ParseStatus,
    request: ParsedRequest,
};

/// Tenta parsear uma request HTTP/1.1 do buffer dado. Retorna:
/// - incomplete: precisa mais bytes
/// - bad: malformed (caller deve fechar conexão)
/// - ok: request completa em `request.body[0..total_len]`
pub fn parseHttp(buf: []const u8) ParseResult {
    const headers_end = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse
        return .{ .status = .incomplete, .request = undefined };

    const headers_len = headers_end + 4;
    // Cabeçalho de request line: "METHOD PATH HTTP/1.1\r\n"
    const first_line_end = std.mem.indexOf(u8, buf[0..headers_end], "\r\n") orelse
        return .{ .status = .bad, .request = undefined };
    const line = buf[0..first_line_end];

    var sp1: usize = 0;
    while (sp1 < line.len and line[sp1] != ' ') sp1 += 1;
    if (sp1 >= line.len) return .{ .status = .bad, .request = undefined };
    var sp2 = sp1 + 1;
    while (sp2 < line.len and line[sp2] != ' ') sp2 += 1;
    if (sp2 >= line.len) return .{ .status = .bad, .request = undefined };
    const method = line[0..sp1];
    const path = line[sp1 + 1 .. sp2];

    const headers_block = buf[0..headers_end];
    const keep_alive = !ihasi(headers_block, "Connection: close");

    if (std.mem.eql(u8, method, "GET")) {
        if (std.mem.eql(u8, path, "/ready")) {
            return .{
                .status = .ok,
                .request = .{
                    .endpoint = .ready,
                    .body = "",
                    .total_len = headers_len,
                    .keep_alive = keep_alive,
                },
            };
        }
        return .{
            .status = .ok,
            .request = .{
                .endpoint = .not_found,
                .body = "",
                .total_len = headers_len,
                .keep_alive = keep_alive,
            },
        };
    }
    if (!std.mem.eql(u8, method, "POST")) {
        return .{
            .status = .ok,
            .request = .{
                .endpoint = .not_found,
                .body = "",
                .total_len = headers_len,
                .keep_alive = keep_alive,
            },
        };
    }
    if (!std.mem.eql(u8, path, "/fraud-score")) {
        return .{
            .status = .ok,
            .request = .{
                .endpoint = .not_found,
                .body = "",
                .total_len = headers_len,
                .keep_alive = keep_alive,
            },
        };
    }

    const cl = parseContentLength(headers_block) orelse return .{ .status = .bad, .request = undefined };
    const total = headers_len + cl;
    if (buf.len < total) return .{ .status = .incomplete, .request = undefined };

    return .{
        .status = .ok,
        .request = .{
            .endpoint = .fraud_score,
            .body = buf[headers_len..total],
            .total_len = total,
            .keep_alive = keep_alive,
        },
    };
}

fn parseContentLength(headers: []const u8) ?usize {
    var i: usize = 0;
    while (i < headers.len) : (i += 1) {
        if (caseEqAt(headers, i, "Content-Length:")) {
            var p = i + "Content-Length:".len;
            while (p < headers.len and (headers[p] == ' ' or headers[p] == '\t')) p += 1;
            var x: usize = 0;
            var seen = false;
            while (p < headers.len and headers[p] >= '0' and headers[p] <= '9') : (p += 1) {
                x = x * 10 + (headers[p] - '0');
                seen = true;
            }
            if (!seen) return null;
            return x;
        }
    }
    return null;
}

fn caseEqAt(buf: []const u8, at: usize, needle: []const u8) bool {
    if (at + needle.len > buf.len) return false;
    var i: usize = 0;
    while (i < needle.len) : (i += 1) {
        const a = std.ascii.toLower(buf[at + i]);
        const b = std.ascii.toLower(needle[i]);
        if (a != b) return false;
    }
    return true;
}

fn ihasi(buf: []const u8, needle: []const u8) bool {
    var i: usize = 0;
    while (i + needle.len <= buf.len) : (i += 1) {
        if (caseEqAt(buf, i, needle)) return true;
    }
    return false;
}

/// Extrai vetor [DIM]f32 do body JSON da Rinha. Assume schema canônico
/// (ordem de campos preservada). Retorna null em malformação.
///
/// Todas as features sao computadas em f64 (igual ao gerador oficial em
/// oficial/data-generator/main.c:507 `normalize`), com round4 unconditional
/// no fim — o ground truth da Rinha sai do KNN brute-force em f64 sobre
/// vetores round4. Diferenca de f32 vs f64 no `amount/cust_avg/10` muda
/// borderline queries e gera FP/FN.
pub fn parseToVector(body: []const u8) ?[c.DIM]f32 {
    var pos: usize = 0;

    pos = findAfter(body, pos, "\"amount\":") orelse return null;
    const amount = parseF64(body, &pos);

    pos = findAfter(body, pos, "\"installments\":") orelse return null;
    const installments = parseU32(body, &pos);

    pos = findAfter(body, pos, "\"requested_at\":\"") orelse return null;
    if (pos + 20 > body.len) return null;
    const req_dt = parseDt(body[pos .. pos + 20]) orelse return null;
    pos += 20;

    pos = findAfter(body, pos, "\"avg_amount\":") orelse return null;
    const cust_avg = parseF64(body, &pos);

    pos = findAfter(body, pos, "\"tx_count_24h\":") orelse return null;
    const tx_count = parseU32(body, &pos);

    pos = findAfter(body, pos, "\"known_merchants\":[") orelse return null;
    const km_start = pos;
    while (pos < body.len and body[pos] != ']') pos += 1;
    const known_merchants = body[km_start..pos];
    if (pos >= body.len) return null;
    pos += 1;

    pos = findAfter(body, pos, "\"merchant\":{\"id\":\"") orelse return null;
    const id_start = pos;
    while (pos < body.len and body[pos] != '"') pos += 1;
    const merchant_id = body[id_start..pos];
    if (pos >= body.len) return null;
    pos += 1;

    pos = findAfter(body, pos, "\"mcc\":\"") orelse return null;
    const mcc_start = pos;
    while (pos < body.len and body[pos] != '"') pos += 1;
    const mcc_bytes = body[mcc_start..pos];
    if (pos >= body.len) return null;
    pos += 1;

    pos = findAfter(body, pos, "\"avg_amount\":") orelse return null;
    const merch_avg = parseF64(body, &pos);

    pos = findAfter(body, pos, "\"is_online\":") orelse return null;
    const is_online = pos < body.len and body[pos] == 't';

    pos = findAfter(body, pos, "\"card_present\":") orelse return null;
    const card_present = pos < body.len and body[pos] == 't';

    pos = findAfter(body, pos, "\"km_from_home\":") orelse return null;
    const km_home = parseF64(body, &pos);

    pos = findAfter(body, pos, "\"last_transaction\":") orelse return null;
    var v5: f64 = -1.0;
    var v6: f64 = -1.0;
    if (pos < body.len and body[pos] == '{') {
        const ts_pos = findAfter(body, pos, "\"timestamp\":\"") orelse return null;
        if (ts_pos + 20 > body.len) return null;
        const lt_dt = parseDt(body[ts_pos .. ts_pos + 20]) orelse return null;
        var p2 = findAfter(body, ts_pos + 20, "\"km_from_current\":") orelse return null;
        const km_current = parseF64(body, &p2);
        const mins = @as(f64, @floatFromInt(req_dt.seconds - lt_dt.seconds)) / 60.0;
        v5 = clamp01f64(mins / 1440.0);
        v6 = clamp01f64(km_current / 1000.0);
    }

    var v: [c.DIM]f64 = undefined;
    v[0] = clamp01f64(amount / 10_000.0);
    v[1] = clamp01f64(@as(f64, @floatFromInt(installments)) / 12.0);
    // C: out[2] = clamp01((amount / cust_avg) / max_ratio). cust_avg eh sempre > 0
    // no gerador (rng_range escolhe baseado em amount); fallback 1.0 alinha com a
    // semantica "se ratio nao definido, considerar acima do limite" se acontecer.
    const ratio = if (cust_avg > 0.0) (amount / cust_avg) / 10.0 else 1.0;
    v[2] = clamp01f64(ratio);
    v[3] = @as(f64, @floatFromInt(req_dt.hour)) / 23.0;
    v[4] = @as(f64, @floatFromInt(req_dt.dow)) / 6.0;
    v[5] = v5;
    v[6] = v6;
    v[7] = clamp01f64(km_home / 1000.0);
    v[8] = clamp01f64(@as(f64, @floatFromInt(tx_count)) / 20.0);
    v[9] = if (is_online) 1.0 else 0.0;
    v[10] = if (card_present) 1.0 else 0.0;
    v[11] = if (containsMerchant(known_merchants, merchant_id)) 0.0 else 1.0;
    v[12] = @as(f64, mcc.risk(mcc_bytes));
    v[13] = clamp01f64(merch_avg / 10_000.0);

    // round4 unconditional em todas as 14 dims, como o gerador faz em
    // oficial/data-generator/main.c:735,774. round4(-1.0) = -1.0 entao
    // sentinels ficam intactos.
    var q: [c.DIM]f32 = undefined;
    comptime var d: usize = 0;
    inline while (d < c.DIM) : (d += 1) {
        const rounded = @round(v[d] * 10000.0) / 10000.0;
        q[d] = @floatCast(rounded);
    }
    return q;
}

fn findAfter(buf: []const u8, start: usize, needle: []const u8) ?usize {
    if (start + needle.len > buf.len) return null;
    var i = start;
    while (i + needle.len <= buf.len) : (i += 1) {
        if (std.mem.eql(u8, buf[i .. i + needle.len], needle)) return i + needle.len;
    }
    return null;
}

fn parseF64(buf: []const u8, pos: *usize) f64 {
    var p = pos.*;
    var neg = false;
    if (p < buf.len and buf[p] == '-') {
        neg = true;
        p += 1;
    }
    var int_part: u64 = 0;
    while (p < buf.len and buf[p] >= '0' and buf[p] <= '9') : (p += 1) {
        int_part = int_part * 10 + (buf[p] - '0');
    }
    var frac_part: u64 = 0;
    var frac_div: u64 = 1;
    if (p < buf.len and buf[p] == '.') {
        p += 1;
        while (p < buf.len and buf[p] >= '0' and buf[p] <= '9') : (p += 1) {
            frac_part = frac_part * 10 + (buf[p] - '0');
            frac_div *= 10;
        }
    }
    pos.* = p;
    const v = @as(f64, @floatFromInt(int_part)) +
        @as(f64, @floatFromInt(frac_part)) / @as(f64, @floatFromInt(frac_div));
    return if (neg) -v else v;
}

fn parseU32(buf: []const u8, pos: *usize) u32 {
    var p = pos.*;
    var x: u32 = 0;
    while (p < buf.len and buf[p] >= '0' and buf[p] <= '9') : (p += 1) {
        x = x * 10 + (buf[p] - '0');
    }
    pos.* = p;
    return x;
}

const Dt = struct { seconds: i64, hour: u8, dow: u8 };

fn parseDt(s: []const u8) ?Dt {
    if (s.len < 19) return null;
    const y = digits(s[0..4]) catch return null;
    const m = @as(i32, @intCast(digits(s[5..7]) catch return null));
    const d = @as(i32, @intCast(digits(s[8..10]) catch return null));
    const h = @as(u8, @intCast(digits(s[11..13]) catch return null));
    const mn = @as(i64, @intCast(digits(s[14..16]) catch return null));
    const sec = @as(i64, @intCast(digits(s[17..19]) catch return null));

    const yi = @as(i32, @intCast(y));
    const yy = if (m <= 2) yi - 1 else yi;
    const era_input = if (yy >= 0) yy else yy - 399;
    const era = @divTrunc(era_input, 400);
    const yoe = @as(u32, @intCast(yy - era * 400));
    const mp = @as(u32, @intCast(if (m > 2) m - 3 else m + 9));
    const doy = (153 * mp + 2) / 5 + @as(u32, @intCast(d)) - 1;
    const doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    const days: i64 = @as(i64, era) * 146097 + @as(i64, @intCast(doe)) - 719468;

    const dow = @as(u8, @intCast(@mod(@mod(days, 7) + 3, 7)));
    const total_sec: i64 = days * 86400 + @as(i64, h) * 3600 + mn * 60 + sec;

    return .{ .seconds = total_sec, .hour = h, .dow = dow };
}

fn digits(buf: []const u8) !u32 {
    var x: u32 = 0;
    for (buf) |ch| {
        if (ch < '0' or ch > '9') return error.BadDigit;
        x = x * 10 + (ch - '0');
    }
    return x;
}

fn containsMerchant(arr: []const u8, id: []const u8) bool {
    var i: usize = 0;
    while (i < arr.len) {
        if (arr[i] == '"') {
            const s = i + 1;
            var e = s;
            while (e < arr.len and arr[e] != '"') e += 1;
            if (std.mem.eql(u8, arr[s..e], id)) return true;
            i = e + 1;
        } else i += 1;
    }
    return false;
}

inline fn clamp01(x: f32) f32 {
    if (x < 0.0) return 0.0;
    if (x > 1.0) return 1.0;
    return x;
}

inline fn clamp01f64(x: f64) f64 {
    if (x < 0.0) return 0.0;
    if (x > 1.0) return 1.0;
    return x;
}

test "parseHttp GET /ready" {
    const buf = "GET /ready HTTP/1.1\r\nHost: x\r\n\r\n";
    const r = parseHttp(buf);
    try testing.expectEqual(ParseStatus.ok, r.status);
    try testing.expectEqual(Endpoint.ready, r.request.endpoint);
    try testing.expectEqual(@as(usize, buf.len), r.request.total_len);
}

test "parseHttp POST /fraud-score incomplete" {
    const buf = "POST /fraud-score HTTP/1.1\r\nContent-Length: 100\r\n\r\n";
    const r = parseHttp(buf);
    try testing.expectEqual(ParseStatus.incomplete, r.status);
}

test "parseHttp POST /fraud-score ok" {
    const body = "{\"amount\":1.0}";
    const buf = "POST /fraud-score HTTP/1.1\r\nContent-Length: 14\r\n\r\n{\"amount\":1.0}";
    const r = parseHttp(buf);
    try testing.expectEqual(ParseStatus.ok, r.status);
    try testing.expectEqualStrings(body, r.request.body);
}

test "parseToVector minimal canonical payload" {
    const payload =
        "{\"id\":\"tx-1\",\"transaction\":{\"amount\":250.0,\"installments\":1,\"requested_at\":\"2026-03-11T03:45:53Z\"}," ++
        "\"customer\":{\"avg_amount\":100.0,\"tx_count_24h\":3,\"known_merchants\":[\"MERC-001\"]}," ++
        "\"merchant\":{\"id\":\"MERC-002\",\"mcc\":\"5411\",\"avg_amount\":200.0}," ++
        "\"terminal\":{\"is_online\":false,\"card_present\":true,\"km_from_home\":12.5}," ++
        "\"last_transaction\":null}";
    const q = parseToVector(payload) orelse return error.ParseFailed;
    try testing.expectApproxEqAbs(@as(f32, 0.025), q[0], 1e-4);
    try testing.expectEqual(SENTINEL_F32, q[5]);
    try testing.expectEqual(@as(f32, 0.15), q[12]);
    try testing.expectEqual(@as(f32, 1.0), q[11]); // MERC-002 not in known_merchants
}
