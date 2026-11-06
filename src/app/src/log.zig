//! std.log override: JSON lines to <app-data>/logs/app.log. Level from LOG_LEVEL (err|warn|info|debug, default info).
//! Each boot moves app.log to app.prev.log (replacing it), so the logs hold this session and the one before.
//! Wire up in main.zig: `pub const std_options: std.Options = .{ .logFn = @import("log.zig").logFn, .log_level = .debug };`
const std = @import("std");

/// Past this many bytes a session stops logging (one marker line says so); the boot lines are the evidence worth keeping.
const max_bytes = 1 << 20;

var file: ?std.Io.File = null;
var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
var dir: []const u8 = ""; // <app-data>/logs once init has run
var pos: u64 = 0; // append offset; every write is under `mutex`
var min_level: std.log.Level = .info;
var mutex: std.Io.Mutex = .init;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Call once at boot, before anything else logs; creates logs/ so a fresh install logs from the first line. Before this, log lines are dropped.
pub fn init(app_data: []const u8) void {
    if (std.c.getenv("LOG_LEVEL")) |v| min_level = std.meta.stringToEnum(std.log.Level, std.mem.span(v)) orelse .info;
    dir = std.fmt.bufPrint(&dir_buf, "{s}/logs", .{app_data}) catch return;
    const d = std.Io.Dir.cwd().createDirPathOpen(io(), dir, .{}) catch return;
    defer d.close(io());
    d.rename("app.log", d, "app.prev.log", io()) catch {}; // FileNotFound on a first boot
    file = d.createFile(io(), "app.log", .{}) catch return;
    pos = 0;
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) void {
    if (@backingInt(level) > @backingInt(min_level)) return; // err=0 ... debug=3
    var msg_buf: [2048]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch msg_buf[0..]; // truncated on overflow
    var out: [4096]u8 = undefined;
    const head = std.fmt.bufPrint(&out, "{{\"ts\":{d},\"level\":\"{s}\",\"scope\":\"{s}\",\"msg\":\"", .{ std.Io.Clock.real.now(io()).toMilliseconds(), @tagName(level), @tagName(scope) }) catch return;
    var n = head.len;
    for (msg) |ch| {
        if (n + 8 > out.len) break;
        switch (ch) {
            '"', '\\' => {
                out[n] = '\\';
                out[n + 1] = ch;
                n += 2;
            },
            '\n' => {
                out[n] = '\\';
                out[n + 1] = 'n';
                n += 2;
            },
            0...9, 11...31 => n += (std.fmt.bufPrint(out[n..], "\\u{x:0>4}", .{ch}) catch return).len,
            else => {
                out[n] = ch;
                n += 1;
            },
        }
    }
    @memcpy(out[n..][0..3], "\"}\n");
    n += 3;
    mutex.lockUncancelable(io());
    defer mutex.unlock(io());
    const f = file orelse return;
    if (pos >= max_bytes) return;
    f.writePositionalAll(io(), out[0..n], pos) catch return;
    pos += n;
    if (pos < max_bytes) return;
    const cap = "{\"level\":\"warn\",\"scope\":\"log\",\"msg\":\"log size cap reached, later lines are dropped\"}\n";
    f.writePositionalAll(io(), cap, pos) catch return;
    pos += cap.len;
}

test "logFn writes an escaped JSON line" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    init(root);
    min_level = .debug;
    logFn(.info, .core, "say \"hi\"\n{d}", .{5});
    logFn(.debug, .net, "second", .{}); // appends after the first line
    file.?.close(io());
    file = null;
    const got = try tmp.dir.readFileAlloc(std.testing.io, "logs/app.log", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(got);
    const nl = std.mem.indexOfScalar(u8, got, '\n').?;
    try std.testing.expect(std.mem.indexOf(u8, got[nl + 1 ..], "\"second\"") != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, got[0..nl], .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("say \"hi\"\n5", parsed.value.object.get("msg").?.string);
    try std.testing.expectEqualStrings("core", parsed.value.object.get("scope").?.string);
}

test "init moves app.log to app.prev.log, replacing an older one" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "logs");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "logs/app.log", .data = "session 1\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "logs/app.prev.log", .data = "session 0\n" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    init(root);
    defer {
        file.?.close(io());
        file = null;
    }
    const prev = try tmp.dir.readFileAlloc(std.testing.io, "logs/app.prev.log", gpa, .limited(64));
    defer gpa.free(prev);
    try std.testing.expectEqualStrings("session 1\n", prev);
}

test "logging stops at the size cap after one marker line" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    init(root);
    min_level = .info;
    pos = max_bytes - 10; // as if the session had already logged ~1 MiB
    logFn(.info, .core, "crosses the cap", .{});
    logFn(.info, .core, "dropped", .{});
    file.?.close(io());
    file = null;
    const got = try tmp.dir.readFileAlloc(std.testing.io, "logs/app.log", gpa, .limited(max_bytes + 4096));
    defer gpa.free(got);
    var lines = std.mem.tokenizeScalar(u8, got[max_bytes - 10 ..], '\n');
    try std.testing.expect(std.mem.indexOf(u8, lines.next().?, "crosses the cap") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines.next().?, "log size cap reached") != null);
    try std.testing.expect(lines.next() == null);
}
