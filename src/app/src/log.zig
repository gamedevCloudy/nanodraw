//! std.log override: JSON lines to <app-data>/logs/app.log. Level from LOG_LEVEL (err|warn|info|debug, default info).
//! Wire up in main.zig: `pub const std_options: std.Options = .{ .logFn = @import("log.zig").logFn, .log_level = .debug };`
const std = @import("std");

var file: ?std.Io.File = null;
var pos: u64 = 0; // append offset; every write is under `mutex`
var min_level: std.log.Level = .info;
var mutex: std.Io.Mutex = .init;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Call once at boot, after the logs/ dir exists (Store.open creates it). Before this, log lines are dropped.
pub fn init(app_data: []const u8) void {
    if (std.c.getenv("LOG_LEVEL")) |v| min_level = std.meta.stringToEnum(std.log.Level, std.mem.span(v)) orelse .info;
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/logs/app.log", .{app_data}) catch return;
    const f = std.Io.Dir.createFileAbsolute(io(), p, .{ .truncate = false }) catch return;
    pos = f.length(io()) catch 0;
    file = f;
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
    if (file) |f| {
        f.writePositionalAll(io(), out[0..n], pos) catch return;
        pos += n;
    }
}

test "logFn writes an escaped JSON line" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "logs");
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
