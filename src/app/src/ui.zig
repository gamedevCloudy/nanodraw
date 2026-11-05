//! The ONLY file that imports NanoUI. One webview window (NanoUI windows are native view OR webview, never a split):
//! the page renders the sidebar and the canvas, served by our loopback server.
//! No close veto exists in NanoUI: closing the window runs `on_close` after the fact (see `onClose`).
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const core = @import("core.zig");
const protocol = @import("protocol.zig");
const view = @import("view.zig");

var gpa: std.mem.Allocator = undefined;
var mailbox: *core.Mailbox = undefined;
var app: *nanoui.App = undefined;
// Cleared by onClose: a closed window's memory is freed, so touching it crashes.
var canvas: ?*nanoui.Window = null;

/// Wire form of CanvasRequest: NanoUI's tsgen has no unions, so `op` is a string enum and `doc` rides beside it.
const Op = enum { load, flush, apply, get_scene, screenshot };
const CanvasWire = struct { request_id: u32, op: Op, doc: ?u32 };
const CanvasEvent = nanoui.Event("canvasRequest", CanvasWire);
/// The sidebar's state; the page renders it and sets the window title itself (FR-W2).
const ViewEvent = nanoui.Event("viewModel", view.ViewModel);

/// JS -> Zig calls (`Bridge.canvasReady()` ...), run on the main thread. Paths posted are gpa-owned; main's core loop frees them.
const Bridge = struct {
    pub const nanoui_params = .{ .canvasReply = .{"r"}, .openPath = .{"path"} };

    pub fn canvasReady(_: *Bridge) void {
        mailbox.post(.canvas_ready);
    }

    pub fn canvasReply(_: *Bridge, r: protocol.CanvasReply) void {
        var own = r;
        if (r.err) |e| own.err = gpa.dupe(u8, e) catch "out of memory"; // call arena is freed after the reply
        mailbox.post(.{ .canvas_reply = own });
    }

    pub fn saveAsRequested(_: *Bridge) void {
        const p = nanoui.dialog.save(gpa, .{ .name = "Untitled.excalidraw", .extensions = &.{"excalidraw"} }) catch return orelse return;
        mailbox.post(.{ .save_as = p });
    }

    pub fn newFile(_: *Bridge) void {
        mailbox.post(.new_file);
    }

    pub fn openFile(_: *Bridge) void {
        const paths = nanoui.dialog.open(gpa, .{ .extensions = &.{ "excalidraw", "json" } }) catch return orelse return;
        defer gpa.free(paths);
        if (paths.len > 0) mailbox.post(.{ .open = paths[0] }); // paths[0] now belongs to the mailbox
    }

    pub fn openPath(_: *Bridge, path: []const u8) void {
        mailbox.post(.{ .open = gpa.dupe(u8, path) catch return });
    }
};
var bridge: Bridge = .{};

/// Creates the app and the one window. Main thread, before the core/net threads emit anything.
pub fn init(init_: std.process.Init, url: []const u8, mb: *core.Mailbox) !void {
    gpa = init_.gpa;
    mailbox = mb;
    // The window closing must not stop the loop before core's quit flush runs; core's `.exit` ends the process.
    app = try nanoui.App.create(init_, .{ .name = "Excalibre", .quit_on_last_window_closed = false });
    try app.bind(&bridge);
    try app.registerEvent(CanvasEvent);
    try app.registerEvent(ViewEvent);
    canvas = try app.newWindow(.{
        .title = "Untitled",
        .width = 1300,
        .height = 800,
        .on_close = .{ .ctx = &bridge, .func = onClose },
        .content = .{ .page = .{ .url = url, .inspectable = builtin.mode == .debug } },
    });
}

pub fn run() void {
    app.run() catch |e| std.log.err("ui run: {s}", .{@errorName(e)});
    if (app.flags.generate_dir != null or app.flags.snapshot != null) std.process.exit(0); // nanoui dev flags: run() returned at once
    // Cmd+Q path: windows are still alive, so core can still flush through the canvas before its `.exit`.
    mailbox.post(.quit);
    while (true) std.Io.sleep(@import("store.zig").io(), .fromSeconds(1), .awake) catch {};
}

/// No veto in NanoUI: the window is already closing. Core still gets `.quit` and exits after its grace period;
/// edits newer than the canvas autosave may be lost on a window-button close (Cmd+Q is fully flushed).
fn onClose(_: *anyopaque, w: *nanoui.Window) void {
    if (canvas == w) canvas = null;
    mailbox.post(.quit);
}

/// Any thread. Event.emit encodes to JSON before returning, so `v` stays the caller's.
pub fn publish(v: view.ViewModel) void {
    if (canvas) |c| ViewEvent.emit(c, v);
}

/// Any thread (Event.emit hops to the main thread itself).
pub fn sendCanvas(req: protocol.CanvasRequest) void {
    const w: CanvasWire = switch (req.op) {
        .load => |d| .{ .request_id = req.request_id, .op = .load, .doc = d },
        .flush => |d| .{ .request_id = req.request_id, .op = .flush, .doc = d },
        .apply => .{ .request_id = req.request_id, .op = .apply, .doc = null },
        .get_scene => .{ .request_id = req.request_id, .op = .get_scene, .doc = null },
        .screenshot => .{ .request_id = req.request_id, .op = .screenshot, .doc = null },
    };
    if (canvas) |c| CanvasEvent.emit(c, w);
}

/// Pre-window fatal error (bind failure).
pub fn fatal(msg: []const u8) void {
    _ = nanoui.dialog.message(.{ .title = "Excalibre", .detail = msg, .kind = .critical });
}

