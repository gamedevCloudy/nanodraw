const std = @import("std");
const core = @import("core.zig");
const store = @import("store.zig");
const net = @import("net.zig");
const ui = @import("ui.zig");
const log = @import("log.zig");
const nanoui = @import("nanoui");

// .debug compiles every level in (release builds default to .info); LOG_LEVEL filters at runtime in log.zig.
pub const std_options: std.Options = .{ .logFn = log.logFn, .log_level = .debug };

const default_port = 7411;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    // NANODRAW_DATA_DIR keeps tests and parallel runs off the real history.
    const app_data = if (init.environ_map.get("NANODRAW_DATA_DIR")) |d| try gpa.dupe(u8, d) else try nanoui.path(gpa, .data, "nanodraw");
    log.init(app_data);

    var st = try store.Store.open(gpa, app_data);
    var mailbox = core.Mailbox.init(gpa);
    var c = try core.Core.init(gpa, &st);

    const port = try portFromEnv(init);
    // Bind failure is fatal: it doubles as the single-instance lock.
    var n = net.Net.listen(gpa, port, &mailbox) catch |e| {
        std.log.err("listen 127.0.0.1:{d}: {s}", .{ port, @errorName(e) });
        var buf: [160]u8 = undefined;
        ui.fatal(std.fmt.bufPrint(&buf, "Cannot listen on 127.0.0.1:{d} ({s}). Is Nanodraw already running?", .{ port, @errorName(e) }) catch "Cannot listen");
        std.process.exit(1);
    };

    std.log.info("boot: nanodraw {s}, data {s}, port {d}", .{ @import("build_options").version, app_data, port });

    // The token travels in the URL hash; the page sends it as a Bearer header.
    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/#{s}", .{ port, n.token });
    try ui.init(init, url, &mailbox); // windows exist before any thread emits

    (try std.Thread.spawn(.{}, net.Net.serve, .{&n})).detach();
    (try std.Thread.spawn(.{}, coreLoop, .{ gpa, &c, &mailbox, &n })).detach();
    ui.run();
}

fn portFromEnv(init: std.process.Init) !u16 {
    const s = init.environ_map.get("EXCALIDRAW_WS_PORT") orelse return default_port;
    return std.fmt.parseInt(u16, s, 10) catch error.InvalidPort;
}

fn coreLoop(gpa: std.mem.Allocator, c: *core.Core, mb: *core.Mailbox, n: *net.Net) void {
    dispatch(gpa, c, n); // initial effects (first view, etc.)
    while (true) {
        if (mb.wait(250)) |ev| {
            c.handle(ev);
            switch (ev) { // ui posts gpa-owned paths; core dupes what it keeps
                .open, .save_as => |p| gpa.free(p),
                else => {},
            }
        }
        c.tick(std.Io.Clock.real.now(store.io()).toMilliseconds());
        dispatch(gpa, c, n);
    }
}

fn dispatch(gpa: std.mem.Allocator, c: *core.Core, n: *net.Net) void {
    for (c.takeEffects()) |eff| switch (eff) {
        .canvas => |req| ui.sendCanvas(req),
        .view => |vm| ui.publish(vm),
        .ws_send => |s| {
            n.send(s.conn, s.frame);
            gpa.free(s.frame);
        },
        .ws_ping => |id| n.ping(id),
        .ws_close => |id| n.close(id),
        .exit => {
            std.log.info("exit", .{});
            std.process.exit(0);
        },
    };
}
