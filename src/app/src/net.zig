//! Loopback listener: embedded assets, /doc/:id, /rpc/:id, and the /mcp WebSocket.
//! Hand-rolled HTTP/1.1 + RFC 6455 over std.Io.net (std.http moves between Zig releases).
//! shortcut: one request per connection (Connection: close), net.mu held across WS writes; upgrade if a slow peer matters.
const std = @import("std");
const core = @import("core.zig");
const protocol = @import("protocol.zig");
const store = @import("store.zig");
const assets = @import("assets");

const log = std.log.scoped(.net);
const netio = std.Io.net;
const ConnId = core.ConnId;
const max_head = 16 * 1024;
const max_body = 256 * 1024 * 1024; // scenes with embedded images
const max_msg = 64 * 1024 * 1024;
const ws_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const blank_scene = "{\"type\":\"excalidraw\",\"version\":2,\"source\":\"nanodraw\",\"elements\":[],\"appState\":{},\"files\":{}}";

pub const Net = struct {
    gpa: std.mem.Allocator,
    server: netio.Server,
    port: u16,
    mailbox: *core.Mailbox,
    token: [32]u8, // per-boot bearer token; main.zig puts it in the page URL hash
    mu: std.Io.Mutex = .init, // guards conns and serializes every WS write
    conns: std.AutoHashMapUnmanaged(ConnId, netio.Stream) = .empty,
    next_conn: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),

    pub fn listen(gpa: std.mem.Allocator, port: u16, mailbox: *core.Mailbox) !Net {
        const addr: netio.IpAddress = .{ .ip4 = .loopback(port) };
        // reuse_address also sets SO_REUSEPORT on macOS, which lets a second instance bind, so the
        // single-instance lock is a connect probe instead. Without reuse a restart hits TIME_WAIT.
        if (addr.connect(io(), .{ .mode = .stream })) |s| {
            s.close(io());
            return error.AddressInUse;
        } else |_| {}
        const server = try addr.listen(io(), .{ .reuse_address = true });
        var raw: [16]u8 = undefined;
        try io().randomSecure(&raw);
        return .{ .gpa = gpa, .server = server, .port = port, .mailbox = mailbox, .token = std.fmt.bytesToHex(raw, .lower) };
    }

    pub fn serve(self: *Net) void {
        while (true) {
            const stream = self.server.accept(io()) catch |e| {
                log.err("accept: {s}", .{@errorName(e)});
                if (e == error.SocketNotListening or e == error.Canceled) return;
                continue;
            };
            const t = std.Thread.spawn(.{}, handleConn, .{ self, stream }) catch |e| {
                log.err("spawn: {s}", .{@errorName(e)});
                stream.close(io());
                continue;
            };
            t.detach();
        }
    }

    pub fn send(self: *Net, conn: ConnId, frame: []const u8) void {
        self.writeFrame(conn, 1, frame);
    }

    pub fn ping(self: *Net, conn: ConnId) void {
        self.writeFrame(conn, 9, "");
    }

    pub fn close(self: *Net, conn: ConnId) void {
        self.writeFrame(conn, 8, &.{ 0x03, 0xe8 });
        self.mu.lockUncancelable(io());
        defer self.mu.unlock(io());
        if (self.conns.get(conn)) |s| s.shutdown(io(), .both) catch {};
    }

    fn writeFrame(self: *Net, conn: ConnId, op: u8, payload: []const u8) void {
        self.mu.lockUncancelable(io());
        defer self.mu.unlock(io());
        const s = self.conns.get(conn) orelse return;
        var h: [10]u8 = undefined;
        h[0] = 0x80 | op;
        var n: usize = 2;
        if (payload.len < 126) {
            h[1] = @intCast(payload.len);
        } else if (payload.len < 65536) {
            h[1] = 126;
            std.mem.writeInt(u16, h[2..4], @intCast(payload.len), .big);
            n = 4;
        } else {
            h[1] = 127;
            std.mem.writeInt(u64, h[2..10], payload.len, .big);
            n = 10;
        }
        writeAll(s, h[0..n]) catch return;
        writeAll(s, payload) catch return;
    }

    fn handleConn(self: *Net, stream: netio.Stream) void {
        defer stream.close(io());
        const buf = self.gpa.alloc(u8, max_head) catch return;
        defer self.gpa.free(buf);
        var r = Reader{ .stream = stream, .buf = buf };
        self.request(&r) catch |e| log.debug("conn: {s}", .{@errorName(e)});
    }

    fn request(self: *Net, r: *Reader) !void {
        const head = try r.readHead();
        const line = head[0 .. std.mem.indexOf(u8, head, "\r\n") orelse head.len];
        var parts = std.mem.splitScalar(u8, line, ' ');
        const method = parts.next() orelse return error.BadRequest;
        const target = parts.next() orelse return error.BadRequest;
        const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];

        if (!self.hostOk(head)) return respond(r.stream, 403, "text/plain", "bad host");
        if (std.mem.eql(u8, path, "/mcp")) return self.mcp(r, head);
        if (std.mem.startsWith(u8, path, "/doc/") or std.mem.startsWith(u8, path, "/rpc/")) {
            if (!self.authOk(head)) return respond(r.stream, 403, "text/plain", "forbidden");
            return self.data(r, head, method, path);
        }
        if (!std.mem.eql(u8, method, "GET")) return respond(r.stream, 405, "text/plain", "method not allowed");
        const want = if (std.mem.eql(u8, path, "/")) "/index.html" else path;
        for (assets.files) |f| {
            if (std.mem.eql(u8, f.path, want)) return respond(r.stream, 200, mime(want), f.data);
        }
        return respond(r.stream, 404, "text/plain", "not found");
    }

    /// guard(): Host must be 127.0.0.1:<port> (blocks DNS rebinding).
    fn hostOk(self: *Net, head: []const u8) bool {
        var buf: [32]u8 = undefined;
        const want = std.fmt.bufPrint(&buf, "127.0.0.1:{d}", .{self.port}) catch return false;
        return std.mem.eql(u8, header(head, "Host") orelse return false, want);
    }

    /// guard() for /doc and /rpc: X-Nanodraw: 1 (needs a CORS preflight we never grant) plus the bearer token.
    fn authOk(self: *Net, head: []const u8) bool {
        const x = header(head, "X-Nanodraw") orelse return false;
        if (!std.mem.eql(u8, x, "1")) return false;
        const a = header(head, "Authorization") orelse return false;
        const pre = "Bearer ";
        return std.mem.startsWith(u8, a, pre) and std.mem.eql(u8, a[pre.len..], &self.token);
    }

    fn data(self: *Net, r: *Reader, head: []const u8, method: []const u8, path: []const u8) !void {
        const s = r.stream;
        const is_doc = path[1] == 'd';
        const id = std.fmt.parseInt(u32, path[5..], 10) catch return respond(s, 404, "text/plain", "bad id");
        if (std.mem.eql(u8, method, "GET")) {
            if (is_doc) {
                var slot = core.Slot(core.DocSource){};
                self.mailbox.post(.{ .doc_read = .{ .doc = id, .out = &slot } });
                slot.done.wait();
                switch (slot.value) {
                    .unknown => return respond(s, 404, "text/plain", "unknown doc"),
                    .blank => return respond(s, 200, "application/json", blank_scene),
                    .file => |p| {
                        const bytes = store.Store.readScene(self.gpa, p) catch return respond(s, 404, "text/plain", "unreadable");
                        defer self.gpa.free(bytes);
                        return respond(s, 200, "application/json", bytes);
                    },
                }
            }
            var slot = core.Slot(?[]u8){};
            self.mailbox.post(.{ .rpc_params = .{ .req = id, .out = &slot } });
            slot.done.wait();
            const bytes = slot.value orelse return respond(s, 404, "text/plain", "no such request");
            defer self.gpa.free(bytes);
            return respond(s, 200, "application/json", bytes);
        }
        if (!std.mem.eql(u8, method, "PUT")) return respond(s, 405, "text/plain", "method not allowed");
        const len = std.fmt.parseInt(usize, header(head, "Content-Length") orelse "", 10) catch return respond(s, 411, "text/plain", "length required");
        if (len > max_body) return respond(s, 413, "text/plain", "too large");
        const body = try self.gpa.alloc(u8, len);
        r.readExact(body) catch |e| {
            self.gpa.free(body);
            return e;
        };
        // body ownership passes to core on post
        if (is_doc) {
            const count = std.fmt.parseInt(u32, header(head, "X-Element-Count") orelse "0", 10) catch 0;
            var slot = core.Slot(core.WriteOutcome){};
            self.mailbox.post(.{ .doc_write = .{ .doc = id, .bytes = body, .count = count, .out = &slot } });
            slot.done.wait();
            switch (slot.value) {
                .ok => return respond(s, 204, "text/plain", ""),
                .unknown_doc => return respond(s, 409, "text/plain", "unknown doc"),
                .failed => |m| return respond(s, 500, "text/plain", m),
            }
        }
        var slot = core.Slot(bool){};
        self.mailbox.post(.{ .rpc_result = .{ .req = id, .bytes = body, .out = &slot } });
        slot.done.wait();
        return respond(s, if (slot.value) 204 else 404, "text/plain", "");
    }

    fn mcp(self: *Net, r: *Reader, head: []const u8) !void {
        const s = r.stream;
        // Browsers always send Origin on WS upgrades; the node `ws` sidecar does not.
        if (header(head, "Origin") != null) return respond(s, 403, "text/plain", "origin not allowed");
        const up = header(head, "Upgrade") orelse return respond(s, 400, "text/plain", "upgrade required");
        const key = header(head, "Sec-WebSocket-Key") orelse return respond(s, 400, "text/plain", "no key");
        if (!std.ascii.eqlIgnoreCase(up, "websocket")) return respond(s, 400, "text/plain", "upgrade required");

        var sha = std.crypto.hash.Sha1.init(.{});
        sha.update(key);
        sha.update(ws_guid);
        var digest: [20]u8 = undefined;
        sha.final(&digest);
        var accept: [28]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&accept, &digest);
        var resp: [160]u8 = undefined;
        const out = try std.fmt.bufPrint(&resp, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{accept});
        try writeAll(s, out);

        const id = self.next_conn.fetchAdd(1, .monotonic);
        self.mu.lockUncancelable(io());
        self.conns.put(self.gpa, id, s) catch {
            self.mu.unlock(io());
            return error.OutOfMemory;
        };
        self.mu.unlock(io());
        self.mailbox.post(.{ .mcp_open = id });
        defer {
            self.mu.lockUncancelable(io());
            _ = self.conns.remove(id);
            self.mu.unlock(io());
            self.mailbox.post(.{ .mcp_closed = id });
        }

        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(self.gpa);
        while (true) {
            var h: [2]u8 = undefined;
            try r.readExact(&h);
            const fin = h[0] & 0x80 != 0;
            const op = h[0] & 0x0f;
            var len: u64 = h[1] & 0x7f;
            if (len == 126) {
                var b: [2]u8 = undefined;
                try r.readExact(&b);
                len = std.mem.readInt(u16, &b, .big);
            } else if (len == 127) {
                var b: [8]u8 = undefined;
                try r.readExact(&b);
                len = std.mem.readInt(u64, &b, .big);
            }
            if (h[1] & 0x80 == 0) return error.UnmaskedFrame; // RFC 6455: clients must mask
            var mask: [4]u8 = undefined;
            try r.readExact(&mask);

            if (op >= 8) {
                if (len > 125) return error.BadFrame;
                var p: [125]u8 = undefined;
                const pl = p[0..@intCast(len)];
                try r.readExact(pl);
                unmask(pl, mask);
                switch (op) {
                    8 => return,
                    9 => self.writeFrame(id, 10, pl),
                    10 => self.mailbox.post(.{ .mcp_pong = id }),
                    else => {},
                }
                continue;
            }
            if (msg.items.len + len > max_msg) return error.FrameTooLarge;
            const old = msg.items.len;
            try msg.resize(self.gpa, old + @as(usize, @intCast(len)));
            try r.readExact(msg.items[old..]);
            unmask(msg.items[old..], mask);
            if (!fin) continue;
            defer msg.clearRetainingCapacity();
            const call = protocol.parseMcpCall(self.gpa, msg.items) catch |e| {
                // no usable id on a bad envelope
                const err = protocol.mcpErr(self.gpa, "", @errorName(e)) catch continue;
                defer self.gpa.free(err);
                self.writeFrame(id, 1, err);
                continue;
            };
            self.mailbox.post(.{ .mcp_call = .{ .conn = id, .call = call } });
        }
    }
};

fn unmask(p: []u8, mask: [4]u8) void {
    for (p, 0..) |*c, i| c.* ^= mask[i % 4];
}

fn header(head: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    _ = it.next(); // request line
    while (it.next()) |line| {
        const i = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(line[0..i], name)) return std.mem.trim(u8, line[i + 1 ..], " \t");
    }
    return null;
}

fn respond(s: netio.Stream, code: u16, ctype: []const u8, body: []const u8) !void {
    const reason = switch (code) {
        200 => "OK",
        204 => "No Content",
        400 => "Bad Request",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        411 => "Length Required",
        413 => "Payload Too Large",
        else => "Error",
    };
    var hdr: [256]u8 = undefined;
    const h = try std.fmt.bufPrint(&hdr, "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ code, reason, ctype, body.len });
    try writeAll(s, h);
    try writeAll(s, body);
}

fn io() std.Io {
    return store.io();
}

fn readSome(s: netio.Stream, dst: []u8) !usize {
    var v = [1][]u8{dst};
    return s.read(io(), &v);
}

fn writeAll(s: netio.Stream, bytes: []const u8) !void {
    var w = s.writer(io(), &.{});
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}

fn mime(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    const table = [_][2][]const u8{
        .{ ".html", "text/html; charset=utf-8" },    .{ ".js", "text/javascript" },
        .{ ".mjs", "text/javascript" },              .{ ".css", "text/css" },
        .{ ".json", "application/json" },            .{ ".svg", "image/svg+xml" },
        .{ ".png", "image/png" },                    .{ ".woff2", "font/woff2" },
        .{ ".woff", "font/woff" },                   .{ ".ttf", "font/ttf" },
        .{ ".wasm", "application/wasm" },            .{ ".map", "application/json" },
    };
    for (table) |e| if (std.mem.eql(u8, ext, e[0])) return e[1];
    return "application/octet-stream";
}

/// Buffered reader: the head and any bytes that arrived with it feed later body/frame reads.
const Reader = struct {
    stream: netio.Stream,
    buf: []u8,
    pos: usize = 0,
    end: usize = 0,

    fn readHead(r: *Reader) ![]const u8 {
        while (true) {
            if (std.mem.indexOf(u8, r.buf[0..r.end], "\r\n\r\n")) |i| {
                r.pos = i + 4;
                return r.buf[0..i];
            }
            if (r.end == r.buf.len) return error.HeadTooLarge;
            const n = try readSome(r.stream, r.buf[r.end..]);
            if (n == 0) return error.EndOfStream;
            r.end += n;
        }
    }

    fn readExact(r: *Reader, dst: []u8) !void {
        var got: usize = 0;
        while (got < dst.len) {
            if (r.pos < r.end) {
                const n = @min(r.end - r.pos, dst.len - got);
                @memcpy(dst[got..][0..n], r.buf[r.pos..][0..n]);
                r.pos += n;
                got += n;
            } else {
                const n = try readSome(r.stream, dst[got..]);
                if (n == 0) return error.EndOfStream;
                got += n;
            }
        }
    }
};

test "header lookup is case-insensitive and skips the request line" {
    const head = "GET /x HTTP/1.1\r\nhost: 127.0.0.1:7411\r\nX-Nanodraw:  1";
    try std.testing.expectEqualStrings("127.0.0.1:7411", header(head, "Host").?);
    try std.testing.expectEqualStrings("1", header(head, "x-nanodraw").?);
    try std.testing.expect(header(head, "Origin") == null);
}

test "shared WS fixture: every ws-calls.jsonl line parses" {
    const gpa = std.testing.allocator;
    const data = @embedFile("ws_calls");
    var it = std.mem.tokenizeScalar(u8, data, '\n');
    var n: usize = 0;
    while (it.next()) |line| {
        const c = try protocol.parseMcpCall(gpa, line);
        gpa.free(c.ws_id);
        gpa.free(c.params);
        n += 1;
    }
    try std.testing.expect(n >= 4);
}
