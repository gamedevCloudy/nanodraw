//! The only mutator. Every file-lifecycle and MCP-routing transition lives in `Core.handle` (DESIGN Q2/Q3).
//!
//! Ownership contracts (the dispatcher in main.zig / net.zig / ui.zig must follow these):
//! - `takeEffects()` slice is valid until the next `handle`/`tick` call. `ws_send.frame` is gpa-owned: the consumer frees it.
//! - A `view` effect's memory is valid for roughly two further `takeEffects` cycles: `ui.publish` should copy what it keeps.
//! - Event payloads are borrowed for the duration of `handle` (Core dupes what it keeps), EXCEPT `mcp_call.call` and
//!   `rpc_result.bytes`, whose gpa-owned memory transfers to Core. `doc_write.bytes` stays owned by the poster (net).
//! - `deinit()` frees pending calls, un-taken `ws_send` frames and the arenas; after `takeEffects` the consumer owns the frames.
//! - `rpc_params` hands the params (gpa-owned) to net, which frees them. It is one-shot per request.
const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("protocol.zig");
const store_mod = @import("store.zig");
const view = @import("view.zig");
const log = std.log.scoped(.core);

pub const DocId = protocol.DocId;
pub const RequestId = protocol.RequestId;
pub const CanvasOp = protocol.CanvasOp;
pub const CanvasReply = protocol.CanvasReply;
pub const CanvasRequest = protocol.CanvasRequest;
pub const McpMethod = protocol.McpMethod;
pub const McpCall = protocol.McpCall;
pub const Path = store_mod.Path;
pub const Doc = store_mod.Doc;
pub const Store = store_mod.Store;

pub const ConnId = u32;
pub const Origin = union(enum) { user, quit, mcp: struct { conn: ConnId, ws_id: []u8, method: McpMethod } };
const Pending = struct { op: CanvasOp, origin: Origin, params: ?[]u8 = null, result: ?[]u8 = null };
pub const UiError = struct { row: ?Path, msg: []const u8 }; // row = null -> banner
/// One-shot completion flag; std.Thread.ResetEvent is gone in 0.17, so this wraps Io.Event with the process-wide Io.
pub const Done = struct {
    ev: std.Io.Event = .unset,
    pub fn set(d: *Done) void {
        d.ev.set(store_mod.io());
    }
    pub fn wait(d: *Done) void {
        d.ev.waitUncancelable(store_mod.io());
    }
    pub fn isSet(d: *const Done) bool {
        return d.ev.isSet();
    }
};
pub fn Slot(comptime T: type) type {
    return struct { value: T = undefined, done: Done = .{} };
}
pub const DocSource = union(enum) { unknown, blank, file: Path };
pub const WriteOutcome = union(enum) { ok, unknown_doc, failed: []const u8 };
pub const Event = union(enum) {
    new_file,
    open: Path,
    save_as: Path,
    quit, // ui.zig
    canvas_ready,
    canvas_reply: CanvasReply, // ui.zig (bridge)
    doc_read: struct { doc: DocId, out: *Slot(DocSource) }, // net.zig
    doc_write: struct { doc: DocId, bytes: []u8, count: u32, out: *Slot(WriteOutcome) },
    rpc_params: struct { req: RequestId, out: *Slot(?[]u8) },
    rpc_result: struct { req: RequestId, bytes: []u8, out: *Slot(bool) },
    mcp_open: ConnId,
    mcp_call: struct { conn: ConnId, call: McpCall },
    mcp_pong: ConnId,
    mcp_closed: ConnId,
};
pub const Effect = union(enum) {
    canvas: CanvasRequest,
    view: view.ViewModel,
    ws_send: struct { conn: ConnId, frame: []u8 },
    ws_ping: ConnId,
    ws_close: ConnId,
    exit,
};

const max_pending = 64;
const ping_every_ms = 5_000;
const silent_ms = 15_000;
const quit_grace_ms = 2_000;

pub const Core = struct {
    gpa: Allocator,
    store: *Store,
    arena: std.heap.ArenaAllocator, // paths and error strings; docs are never pruned
    view_arenas: [2]std.heap.ArenaAllocator, // alternate per takeEffects so a vm outlives its batch by one cycle
    vi: u1 = 0,
    taken: bool = false,
    docs: std.AutoHashMapUnmanaged(DocId, Doc) = .empty,
    active: DocId = 0,
    pending: std.AutoArrayHashMapUnmanaged(RequestId, Pending) = .empty,
    conns: std.AutoHashMapUnmanaged(ConnId, i64) = .empty,
    canvas_ready: bool = false,
    err: ?UiError = null,
    quit_at: ?i64 = null,
    next_id: u32 = 1,
    last_ping: i64 = 0,
    effects: std.ArrayList(Effect) = .empty,

    pub fn init(gpa: Allocator, store: *Store) !Core {
        var self = Core{
            .gpa = gpa,
            .store = store,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .view_arenas = .{ std.heap.ArenaAllocator.init(gpa), std.heap.ArenaAllocator.init(gpa) },
        };
        self.active = try self.issue(.{ .path = null, .row = null });
        return self;
    }

    /// Frees everything Core owns: pending calls, un-taken ws_send frames, arenas. The owner of `store` closes it.
    pub fn deinit(self: *Core) void {
        for (self.pending.values()) |p| self.freePending(p);
        self.pending.deinit(self.gpa);
        if (!self.taken) for (self.effects.items) |e| if (e == .ws_send) self.gpa.free(e.ws_send.frame);
        self.effects.deinit(self.gpa);
        self.docs.deinit(self.gpa);
        self.conns.deinit(self.gpa);
        self.arena.deinit();
        for (&self.view_arenas) |*a| a.deinit();
    }

    pub fn handle(self: *Core, ev: Event) void {
        self.begin();
        self.handleInner(ev) catch |e| log.err("handle failed: {s}", .{@errorName(e)}); // shortcut: OOM may leak an event's payload
    }

    pub fn tick(self: *Core, now_ms: i64) void {
        self.begin();
        if (now_ms - self.last_ping >= ping_every_ms) {
            self.last_ping = now_ms;
            var it = self.conns.iterator();
            while (it.next()) |e| self.push(.{ .ws_ping = e.key_ptr.* });
        }
        var stale: std.ArrayList(ConnId) = .empty;
        defer stale.deinit(self.gpa);
        var it = self.conns.iterator();
        while (it.next()) |e| {
            if (now_ms - e.value_ptr.* > silent_ms) stale.append(self.gpa, e.key_ptr.*) catch return;
        }
        for (stale.items) |id| {
            _ = self.conns.remove(id);
            self.push(.{ .ws_close = id });
        }
        if (stale.items.len > 0) self.publish() catch {};
        if (self.quit_at) |q| if (now_ms >= q) {
            self.quit_at = null;
            self.push(.exit);
        };
    }

    pub fn takeEffects(self: *Core) []Effect {
        if (self.taken) return &.{}; // already handed out: a second take must not re-deliver (double free of frames)
        self.taken = true;
        const out = self.effects.items;
        self.vi ^= 1; // next batch's views go to the arena that held the batch before this one
        _ = self.view_arenas[self.vi].reset(.retain_capacity);
        return out;
    }

    // ---- internals ----

    fn begin(self: *Core) void {
        if (self.taken) {
            self.effects.clearRetainingCapacity();
            self.taken = false;
        }
    }

    fn push(self: *Core, e: Effect) void {
        self.effects.append(self.gpa, e) catch log.err("effect dropped: out of memory", .{});
    }

    fn nowMs() i64 {
        return std.Io.Clock.real.now(store_mod.io()).toMilliseconds();
    }

    fn issue(self: *Core, doc: Doc) !DocId {
        const id = self.next_id;
        try self.docs.put(self.gpa, id, doc);
        self.next_id += 1;
        return id;
    }

    fn submit(self: *Core, op: CanvasOp, origin: Origin, params: ?[]u8) error{ Busy, OutOfMemory }!RequestId {
        if (self.pending.count() >= max_pending) return error.Busy;
        const rid = self.next_id;
        try self.pending.put(self.gpa, rid, .{ .op = op, .origin = origin, .params = params });
        errdefer _ = self.pending.swapRemove(rid);
        try self.effects.append(self.gpa, .{ .canvas = .{ .request_id = rid, .op = op } });
        self.next_id += 1;
        return rid;
    }

    fn setErr(self: *Core, row: ?Path, msg: []const u8) !void {
        const a = self.arena.allocator();
        self.err = .{ .row = if (row) |r| try a.dupe(u8, r) else null, .msg = try a.dupe(u8, msg) };
    }

    fn submitFailed(self: *Core, e: anyerror) void {
        self.setErr(null, if (e == error.Busy) "busy" else "out of memory") catch {};
        self.publish() catch {};
    }

    fn publish(self: *Core) !void {
        const a = self.view_arenas[self.vi].allocator();
        const rows = try self.store.list(a);
        const active = self.docs.get(self.active) orelse Doc{ .path = null, .row = null };
        const vm = try view.build(a, rows, active, self.err, self.canvas_ready, self.conns.count(), std.Io.Clock.real.now(store_mod.io()).toSeconds());
        try self.effects.append(self.gpa, .{ .view = vm });
    }

    fn freePending(self: *Core, p: Pending) void {
        if (p.origin == .mcp) self.gpa.free(p.origin.mcp.ws_id);
        if (p.params) |x| self.gpa.free(x);
        if (p.result) |x| self.gpa.free(x);
    }

    fn sendFrame(self: *Core, conn: ConnId, frame: []u8) void {
        if (!self.conns.contains(conn)) return self.gpa.free(frame);
        self.push(.{ .ws_send = .{ .conn = conn, .frame = frame } });
    }

    /// Deliver a finished (or failed) pending call to whoever asked. Consumes `p`.
    fn route(self: *Core, p: Pending, err: ?[]const u8) !void {
        defer self.freePending(p);
        switch (p.origin) {
            .quit => self.push(.exit),
            .user => if (err) |m| try self.setErr(null, m),
            .mcp => |m| {
                if (!self.conns.contains(m.conn)) return;
                const frame = blk: {
                    if (err) |e| break :blk try protocol.mcpErr(self.gpa, m.ws_id, e);
                    switch (m.method) {
                        .apply_patch => break :blk try protocol.mcpOk(self.gpa, m.ws_id, "{}"),
                        .get_scene, .screenshot => {
                            const r = p.result orelse break :blk try protocol.mcpErr(self.gpa, m.ws_id, "canvas returned no result");
                            break :blk try protocol.mcpOk(self.gpa, m.ws_id, r);
                        },
                        .save => {
                            const path = (self.docs.get(p.op.flush) orelse Doc{ .path = null, .row = null }).path orelse
                                break :blk try protocol.mcpErr(self.gpa, m.ws_id, "no file path after save");
                            const q = try protocol.quote(self.gpa, path);
                            defer self.gpa.free(q);
                            const body = try std.fmt.allocPrint(self.gpa, "{{\"path\":{s}}}", .{q});
                            defer self.gpa.free(body);
                            break :blk try protocol.mcpOk(self.gpa, m.ws_id, body);
                        },
                    }
                };
                self.sendFrame(m.conn, frame);
            },
        }
    }

    fn rejectMcp(self: *Core, conn: ConnId, call: McpCall, msg: []const u8) !void {
        defer self.gpa.free(call.ws_id);
        defer self.gpa.free(call.params);
        self.sendFrame(conn, try protocol.mcpErr(self.gpa, call.ws_id, msg));
    }

    fn handleInner(self: *Core, ev: Event) !void {
        switch (ev) {
            .new_file => {
                if (!self.canvas_ready) return self.notReady();
                const id = try self.issue(.{ .path = null, .row = null });
                // flush materializes Untitled-N + its row now (FR-F1)
                _ = self.submit(.{ .load = id }, .user, null) catch |e| return self.submitFailed(e);
                _ = self.submit(.{ .flush = id }, .user, null) catch |e| return self.submitFailed(e);
            },
            .open => |p| {
                if (!self.canvas_ready) return self.notReady();
                const cur = self.docs.get(self.active).?;
                if (cur.path != null and std.mem.eql(u8, cur.path.?, p)) { // re-click = touch only
                    try self.store.touch(p, std.Io.Clock.real.now(store_mod.io()).toSeconds());
                    return self.publish();
                }
                const path = try self.arena.allocator().dupe(u8, p);
                const id = try self.issue(.{ .path = path, .row = path });
                _ = self.submit(.{ .load = id }, .user, null) catch |e| return self.submitFailed(e);
            },
            .save_as => |p| {
                if (!self.canvas_ready) return self.notReady();
                const d = self.docs.getPtr(self.active).?;
                d.path = try self.arena.allocator().dupe(u8, p);
                _ = self.submit(.{ .flush = self.active }, .user, null) catch |e| {
                    d.path = d.row;
                    return self.submitFailed(e);
                };
            },
            .quit => {
                self.quit_at = nowMs() + quit_grace_ms;
                if (self.submit(.{ .flush = self.active }, .quit, null)) |_| {} else |_| self.push(.exit);
            },
            .canvas_ready => {
                for (self.pending.values()) |p| try self.route(p, "canvas reloaded");
                self.pending.clearRetainingCapacity();
                self.canvas_ready = true;
                self.err = null;
                _ = self.submit(.{ .load = self.active }, .user, null) catch |e| return self.submitFailed(e);
                try self.publish();
            },
            .canvas_reply => |r| {
                const kv = self.pending.fetchSwapRemove(r.request_id) orelse {
                    log.debug("late reply for request {d}", .{r.request_id});
                    return;
                };
                const p = kv.value;
                if (r.err == null) switch (p.op) {
                    .load => |id| {
                        self.active = id;
                        self.err = null;
                        if (self.docs.get(id).?.path) |path| try self.store.touch(path, std.Io.Clock.real.now(store_mod.io()).toSeconds());
                    },
                    else => {},
                };
                try self.route(p, r.err);
                if (r.err) |m| if (p.op == .load) if (self.docs.get(p.op.load).?.path) |path| { // name the file in the banner
                    try self.setErr(null, try std.fmt.allocPrint(self.arena.allocator(), "Couldn't open {s}: {s}", .{ std.fs.path.basename(path), m }));
                };
                try self.publish();
            },
            .doc_read => |r| {
                r.out.value = if (self.docs.get(r.doc)) |d|
                    (if (d.path) |p| DocSource{ .file = p } else DocSource.blank)
                else
                    DocSource.unknown;
                r.out.done.set();
            },
            .doc_write => |w| {
                w.out.value = try self.writeDoc(w.doc, w.bytes, w.count);
                w.out.done.set();
            },
            .rpc_params => |r| {
                r.out.value = null;
                if (self.pending.getPtr(r.req)) |p| {
                    r.out.value = p.params;
                    p.params = null;
                }
                r.out.done.set();
            },
            .rpc_result => |r| {
                if (self.pending.getPtr(r.req)) |p| {
                    if (p.result) |old| self.gpa.free(old);
                    p.result = r.bytes;
                    r.out.value = true;
                } else {
                    self.gpa.free(r.bytes);
                    r.out.value = false;
                }
                r.out.done.set();
            },
            .mcp_open => |id| {
                try self.conns.put(self.gpa, id, nowMs());
                try self.publish();
            },
            .mcp_pong => |id| if (self.conns.getPtr(id)) |t| {
                t.* = nowMs(); // a pong after close must not resurrect the conn
            },
            .mcp_closed => |id| if (self.conns.remove(id)) try self.publish(),
            .mcp_call => |m| {
                const call = m.call;
                if (!self.canvas_ready) return self.rejectMcp(m.conn, call, "canvas not ready");
                const op: CanvasOp = switch (call.method) {
                    .apply_patch => .apply,
                    .get_scene => .get_scene,
                    .screenshot => .screenshot,
                    .save => .{ .flush = self.active },
                };
                const origin = Origin{ .mcp = .{ .conn = m.conn, .ws_id = @constCast(call.ws_id), .method = call.method } };
                _ = self.submit(op, origin, @constCast(call.params)) catch |e| {
                    return self.rejectMcp(m.conn, call, if (e == error.Busy) "busy" else "out of memory");
                };
            },
        }
    }

    fn notReady(self: *Core) !void {
        try self.setErr(null, "canvas not ready");
        try self.publish();
    }

    fn writeDoc(self: *Core, id: DocId, bytes: []const u8, count: u32) !WriteOutcome {
        const d = self.docs.getPtr(id) orelse return .unknown_doc;
        const written = self.store.write(d.*, bytes, count, std.Io.Clock.real.now(store_mod.io()).toSeconds()) catch |e| {
            d.path = d.row;
            try self.setErr(d.row, @errorName(e));
            try self.publish();
            return .{ .failed = @errorName(e) };
        };
        defer self.gpa.free(written);
        const path = try self.arena.allocator().dupe(u8, written);
        d.path = path;
        d.row = path;
        if (self.err) |e| if (e.row) |r| {
            if (std.mem.eql(u8, r, path)) self.err = null;
        };
        try self.publish();
        return .ok;
    }
};

pub const Mailbox = struct {
    gpa: Allocator,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    items: std.ArrayList(Event) = .empty,

    pub fn init(gpa: Allocator) Mailbox {
        return .{ .gpa = gpa };
    }

    pub fn post(self: *Mailbox, ev: Event) void { // any thread, never blocks on core work
        const io = store_mod.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.items.append(self.gpa, ev) catch return log.err("event dropped: out of memory", .{});
        self.cond.signal(io);
    }

    pub fn wait(self: *Mailbox, timeout_ms: u32) ?Event { // core thread
        const io = store_mod.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.items.items.len == 0) {
            self.cond.waitTimeout(io, &self.mutex, .{ .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake } }) catch {};
        }
        if (self.items.items.len == 0) return null;
        return self.items.orderedRemove(0);
    }
};

// ---- tests (real Store on a temp dir; std.testing.allocator, so leaks and double frees fail the run) ----

const Fixture = struct {
    tmp: std.testing.TmpDir,
    store: Store,
    core: Core,

    fn init(f: *Fixture) !void {
        const gpa = std.testing.allocator;
        f.tmp = std.testing.tmpDir(.{});
        const root = try f.tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
        defer gpa.free(root);
        f.store = try Store.open(gpa, root); // dupes root
        f.core = try Core.init(gpa, &f.store);
    }
    fn deinit(f: *Fixture) void {
        f.core.deinit();
        f.store.close();
        f.tmp.cleanup();
    }
    fn canvasReqs(f: *Fixture) !std.ArrayList(CanvasRequest) {
        var l: std.ArrayList(CanvasRequest) = .empty;
        for (f.core.takeEffects()) |e| if (e == .canvas) try l.append(std.testing.allocator, e.canvas);
        return l;
    }
};

/// Test consumer: takes the batch, frees every ws_send frame except the last, which it returns (caller frees).
fn lastFrame(c: *Core) ?[]u8 {
    var last: ?[]u8 = null;
    for (c.takeEffects()) |e| if (e == .ws_send) {
        if (last) |l| std.testing.allocator.free(l);
        last = e.ws_send.frame;
    };
    return last;
}

test "core: ready -> new_file -> write -> sidebar row; failed load keeps active" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const c = &f.core;
    const scratch = c.active;

    c.handle(.new_file); // before ready: banner, no canvas call
    var reqs = try f.canvasReqs();
    try std.testing.expectEqual(@as(usize, 0), reqs.items.len);
    reqs.deinit(std.testing.allocator);

    c.handle(.canvas_ready);
    reqs = try f.canvasReqs();
    try std.testing.expectEqual(@as(usize, 1), reqs.items.len);
    try std.testing.expectEqual(scratch, reqs.items[0].op.load);
    c.handle(.{ .canvas_reply = .{ .request_id = reqs.items[0].request_id, .err = null } });
    reqs.deinit(std.testing.allocator);
    try std.testing.expectEqual(scratch, c.active);
    _ = c.takeEffects();

    c.handle(.new_file);
    reqs = try f.canvasReqs();
    defer reqs.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), reqs.items.len);
    const new_id = reqs.items[0].op.load;
    try std.testing.expectEqual(new_id, reqs.items[1].op.flush);
    try std.testing.expect(c.active == scratch); // active only switches on load ok

    c.handle(.{ .canvas_reply = .{ .request_id = reqs.items[0].request_id, .err = null } });
    try std.testing.expectEqual(new_id, c.active);

    var slot = Slot(WriteOutcome){};
    c.handle(.{ .doc_write = .{ .doc = new_id, .bytes = @constCast("{}"), .count = 0, .out = &slot } });
    try std.testing.expect(slot.done.isSet());
    try std.testing.expect(slot.value == .ok);
    var bad = Slot(WriteOutcome){};
    c.handle(.{ .doc_write = .{ .doc = 9999, .bytes = @constCast("{}"), .count = 0, .out = &bad } });
    try std.testing.expect(bad.value == .unknown_doc);

    c.handle(.{ .canvas_reply = .{ .request_id = reqs.items[1].request_id, .err = null } });
    var saw_row = false;
    for (c.takeEffects()) |e| if (e == .view and e.view.sections.len == 1) {
        saw_row = e.view.sections[0].rows.len == 1 and e.view.sections[0].rows[0].active;
    };
    try std.testing.expect(saw_row);

    // failed load: active unchanged, banner shown
    c.handle(.{ .open = "/nope/x.excalidraw" });
    var r2 = try f.canvasReqs();
    defer r2.deinit(std.testing.allocator);
    const before = c.active;
    c.handle(.{ .canvas_reply = .{ .request_id = r2.items[0].request_id, .err = "bad file" } });
    try std.testing.expectEqual(before, c.active);
    try std.testing.expectEqualStrings("Couldn't open x.excalidraw: bad file", c.err.?.msg);
    // a second reply for the same request is consumed once and ignored
    c.handle(.{ .canvas_reply = .{ .request_id = r2.items[0].request_id, .err = null } });
    try std.testing.expectEqual(before, c.active);
}

test "core: mcp get_scene routes result; rejects before ready; save returns path; closed conn drops replies" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const c = &f.core;
    const gpa = std.testing.allocator;

    c.handle(.{ .mcp_open = 1 });
    const early = try protocol.parseMcpCall(gpa, "{\"id\":\"a\",\"method\":\"canvas.getScene\"}");
    c.handle(.{ .mcp_call = .{ .conn = 1, .call = early } });
    const rej = lastFrame(c).?;
    defer gpa.free(rej);
    try std.testing.expect(std.mem.indexOf(u8, rej, "canvas not ready") != null);

    c.handle(.canvas_ready);
    var reqs0 = try f.canvasReqs();
    c.handle(.{ .canvas_reply = .{ .request_id = reqs0.items[0].request_id, .err = null } });
    reqs0.deinit(gpa);
    _ = c.takeEffects();

    const call = try protocol.parseMcpCall(gpa, "{\"id\":\"b\",\"method\":\"canvas.getScene\"}");
    c.handle(.{ .mcp_call = .{ .conn = 1, .call = call } });
    var reqs = try f.canvasReqs();
    defer reqs.deinit(gpa);
    const rid = reqs.items[0].request_id;
    try std.testing.expect(reqs.items[0].op == .get_scene);
    var s = Slot(bool){};
    c.handle(.{ .rpc_result = .{ .req = rid, .bytes = try gpa.dupe(u8, "{\"elements\":[]}"), .out = &s } });
    try std.testing.expect(s.value);
    c.handle(.{ .canvas_reply = .{ .request_id = rid, .err = null } });
    const got = lastFrame(c).?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings("{\"id\":\"b\",\"result\":{\"elements\":[]}}", got);

    // save: flush(active) then reply carries the path once the doc has been written
    const sv = try protocol.parseMcpCall(gpa, "{\"id\":\"c\",\"method\":\"file.save\"}");
    c.handle(.{ .mcp_call = .{ .conn = 1, .call = sv } });
    var r3 = try f.canvasReqs();
    defer r3.deinit(gpa);
    try std.testing.expectEqual(c.active, r3.items[0].op.flush);
    var w = Slot(WriteOutcome){};
    c.handle(.{ .doc_write = .{ .doc = c.active, .bytes = @constCast("{}"), .count = 0, .out = &w } });
    c.handle(.{ .canvas_reply = .{ .request_id = r3.items[0].request_id, .err = null } });
    const saved = lastFrame(c).?;
    defer gpa.free(saved);
    try std.testing.expect(std.mem.indexOf(u8, saved, "Untitled-1.excalidraw") != null);

    // closed conn: the in-flight call completes on the canvas side, but no frame is sent and nothing leaks
    const c2 = try protocol.parseMcpCall(gpa, "{\"id\":\"d\",\"method\":\"canvas.applyPatch\",\"params\":{}}");
    c.handle(.{ .mcp_call = .{ .conn = 1, .call = c2 } });
    var r4 = try f.canvasReqs();
    defer r4.deinit(gpa);
    try std.testing.expect(r4.items[0].op == .apply);
    c.handle(.{ .mcp_closed = 1 });
    c.handle(.{ .canvas_reply = .{ .request_id = r4.items[0].request_id, .err = null } });
    try std.testing.expect(lastFrame(c) == null);
    // a late pong must not resurrect the closed conn
    c.handle(.{ .mcp_pong = 1 });
    try std.testing.expect(!c.conns.contains(1));
    // and a new call on the dead conn is accepted by core but its reply is still dropped
    const c3 = try protocol.parseMcpCall(gpa, "{\"id\":\"e\",\"method\":\"canvas.getScene\"}");
    c.handle(.{ .mcp_call = .{ .conn = 1, .call = c3 } });
    var r5 = try f.canvasReqs();
    defer r5.deinit(gpa);
    c.handle(.{ .canvas_reply = .{ .request_id = r5.items[0].request_id, .err = "boom" } });
    try std.testing.expect(lastFrame(c) == null);
}

test "core: pending mcp call is freed when the canvas reloads or core is torn down" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const c = &f.core;
    const gpa = std.testing.allocator;
    c.handle(.{ .mcp_open = 2 });
    c.handle(.canvas_ready);
    _ = c.takeEffects();
    const call = try protocol.parseMcpCall(gpa, "{\"id\":\"p\",\"method\":\"canvas.screenshot\"}");
    c.handle(.{ .mcp_call = .{ .conn = 2, .call = call } });
    _ = c.takeEffects();
    c.handle(.canvas_ready); // reload: the in-flight call gets an error frame
    const fr = lastFrame(c).?;
    defer gpa.free(fr);
    try std.testing.expect(std.mem.indexOf(u8, fr, "canvas reloaded") != null);
    // leave one pending call and an un-taken frame for deinit to free
    const call2 = try protocol.parseMcpCall(gpa, "{\"id\":\"q\",\"method\":\"canvas.getScene\"}");
    c.handle(.{ .mcp_call = .{ .conn = 2, .call = call2 } });
}

test "mailbox: post/wait order, timeout" {
    var mb = Mailbox.init(std.testing.allocator);
    defer mb.items.deinit(std.testing.allocator);
    try std.testing.expect(mb.wait(1) == null);
    mb.post(.new_file);
    mb.post(.quit);
    try std.testing.expect(mb.wait(1).? == .new_file);
    try std.testing.expect(mb.wait(1).? == .quit);
}

test "core: tick pings, closes silent conns, quit deadline" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const c = &f.core;
    c.handle(.{ .mcp_open = 7 });
    const t0 = Core.nowMs();
    c.tick(t0 + 6_000);
    var pinged = false;
    for (c.takeEffects()) |e| if (e == .ws_ping) {
        pinged = true;
    };
    try std.testing.expect(pinged);
    c.tick(t0 + 20_000);
    var closed = false;
    for (c.takeEffects()) |e| if (e == .ws_close) {
        closed = true;
    };
    try std.testing.expect(closed);

    c.handle(.quit); // canvas not ready is fine: flush is still submitted
    _ = c.takeEffects();
    c.tick(Core.nowMs() + 3_000);
    var exited = false;
    for (c.takeEffects()) |e| if (e == .exit) {
        exited = true;
    };
    try std.testing.expect(exited);
}

fn lastAgents(c: *Core) ?u32 {
    var n: ?u32 = null;
    for (c.takeEffects()) |e| if (e == .view) {
        n = e.view.agents;
    };
    return n;
}

test "core: view carries the live agent count on open, close and silent drop" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const c = &f.core;
    c.handle(.{ .mcp_open = 1 });
    try std.testing.expectEqual(@as(?u32, 1), lastAgents(c));
    c.handle(.{ .mcp_open = 2 });
    try std.testing.expectEqual(@as(?u32, 2), lastAgents(c));
    c.handle(.{ .mcp_closed = 1 });
    try std.testing.expectEqual(@as(?u32, 1), lastAgents(c));
    c.handle(.{ .mcp_closed = 1 }); // already gone: no re-render
    try std.testing.expectEqual(@as(?u32, null), lastAgents(c));
    c.tick(Core.nowMs() + 20_000); // conn 2 went silent
    try std.testing.expectEqual(@as(?u32, 0), lastAgents(c));
}
