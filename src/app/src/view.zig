//! Pure ViewModel build; `localDay` is the only libc call.
const std = @import("std");
const Allocator = std.mem.Allocator;
const store = @import("store.zig");
const core = @import("core.zig");
// libc time.h subset (no @cImport in 0.17). Layout of the leading ints is the same on macOS/glibc/musl.
const tz = struct {
    pub const Tm = extern struct { tm_sec: c_int, tm_min: c_int, tm_hour: c_int, tm_mday: c_int, tm_mon: c_int, tm_year: c_int, tm_wday: c_int, tm_yday: c_int, tm_isdst: c_int, tm_gmtoff: c_long, tm_zone: ?[*:0]const u8 };
    pub extern fn localtime_r(t: *const i64, out: *Tm) ?*Tm;
};

const Path = store.Path;
const FileRecord = store.FileRecord;
const Doc = store.Doc;

pub const ViewModel = struct { title: []const u8, enabled: bool, banner: ?[]const u8, sections: []Section }; // sections empty -> "No files yet"
pub const Section = struct { header: []const u8, rows: []Row };
pub const Row = struct { path: Path, label: []const u8, active: bool, err: ?[]const u8, count: u32, opened_at: i64, dir: ?[]const u8 = null }; // dir: parent folder name, only when another row shares the basename

/// All allocations come from `gpa` (core passes an arena); row paths/labels borrow from `rows`/`active`/`err`.
pub fn build(gpa: Allocator, rows: []const FileRecord, active: Doc, err: ?core.UiError, enabled: bool, now: i64) !ViewModel {
    const sections = try groupByDay(gpa, rows, now, localDay);
    for (sections) |s| for (s.rows) |*r| {
        r.active = if (active.path) |p| std.mem.eql(u8, p, r.path) else false;
        if (err) |e| if (e.row) |er| {
            if (std.mem.eql(u8, er, r.path)) r.err = e.msg;
        };
    };
    return .{
        .title = if (active.path) |p| std.fs.path.basename(p) else "Untitled",
        .enabled = enabled,
        .banner = if (err) |e| (if (e.row == null) e.msg else null) else null,
        .sections = sections,
    };
}

/// `rows` must be newest-first (as `Store.list` returns them).
pub fn groupByDay(gpa: Allocator, rows: []const FileRecord, now: i64, dayOf: *const fn (i64) i32) ![]Section {
    const today = dayOf(now);
    const flat = try gpa.alloc(Row, rows.len);
    var out: std.ArrayList(Section) = .empty;
    var start: usize = 0;
    for (rows, 0..) |r, i| {
        flat[i] = .{ .path = r.path, .label = std.fs.path.basename(r.path), .active = false, .err = null, .count = r.element_count, .opened_at = r.opened_at };
        const day = dayOf(r.opened_at);
        const last = i + 1 == rows.len or dayOf(rows[i + 1].opened_at) != day;
        if (!last) continue;
        try out.append(gpa, .{ .header = try header(gpa, day, today), .rows = flat[start .. i + 1] });
        start = i + 1;
    }
    for (flat, 0..) |*r, i| for (flat, 0..) |o, j| {
        if (i != j and std.mem.eql(u8, r.label, o.label)) {
            r.dir = std.fs.path.basename(std.fs.path.dirname(r.path) orelse "");
            break;
        }
    };
    return out.toOwnedSlice(gpa);
}

fn header(gpa: Allocator, day: i32, today: i32) ![]const u8 {
    if (day == today) return "Today";
    if (day == today - 1) return "Yesterday";
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const ymd = civilFromDays(day);
    return std.fmt.allocPrint(gpa, "{s} {d}, {d}", .{ months[ymd.m - 1], ymd.d, ymd.y });
}

/// Epoch-day in the local timezone (DST-correct: localtime_r per timestamp).
pub fn localDay(unix_s: i64) i32 {
    var tm: tz.Tm = undefined;
    if (tz.localtime_r(&unix_s, &tm) == null) return @intCast(@divFloor(unix_s, 86400)); // out-of-range: UTC day
    return daysFromCivil(tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday);
}

// Howard Hinnant's civil <-> days algorithms (days since 1970-01-01).
fn daysFromCivil(y_in: i32, m: i32, d: i32) i32 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = if (m > 2) m - 3 else m + 9;
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn civilFromDays(z_in: i32) struct { y: i32, m: usize, d: i32 } {
    const z = z_in + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m: i32 = if (mp < 10) mp + 3 else mp - 9;
    return .{ .y = yoe + era * 400 + @as(i32, if (m <= 2) 1 else 0), .m = @intCast(m), .d = d };
}

fn utcDay(s: i64) i32 {
    return @intCast(@divFloor(s, 86400));
}

test "civil round trip" {
    const d = daysFromCivil(2026, 11, 3);
    const c = civilFromDays(d);
    try std.testing.expectEqual(@as(i32, 2026), c.y);
    try std.testing.expectEqual(@as(usize, 11), c.m);
    try std.testing.expectEqual(@as(i32, 3), c.d);
    try std.testing.expectEqual(@as(i32, 0), daysFromCivil(1970, 1, 1));
}

test "groupByDay: Today / Yesterday / dated, newest first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nov3: i64 = @as(i64, daysFromCivil(2026, 11, 3)) * 86400;
    const now = nov3 + 3 * 86400 + 100;
    const rows = [_]FileRecord{
        .{ .id = 1, .path = "/d/a.excalidraw", .opened_at = now - 10, .element_count = 0 },
        .{ .id = 2, .path = "/d/b.excalidraw", .opened_at = now - 20, .element_count = 0 },
        .{ .id = 3, .path = "/d/c.excalidraw", .opened_at = now - 86400, .element_count = 0 },
        .{ .id = 4, .path = "/d/d.excalidraw", .opened_at = nov3 + 5, .element_count = 0 },
    };
    const secs = try groupByDay(a, &rows, now, utcDay);
    try std.testing.expectEqual(@as(usize, 3), secs.len);
    try std.testing.expectEqualStrings("Today", secs[0].header);
    try std.testing.expectEqual(@as(usize, 2), secs[0].rows.len);
    try std.testing.expectEqualStrings("Yesterday", secs[1].header);
    try std.testing.expectEqualStrings("Nov 3, 2026", secs[2].header);
    try std.testing.expectEqualStrings("d.excalidraw", secs[2].rows[0].label);
    try std.testing.expectEqual(@as(usize, 0), (try groupByDay(a, &.{}, now, utcDay)).len);
}

test "groupByDay: dir only on basename collisions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rows = [_]FileRecord{
        .{ .id = 1, .path = "/Documents/a.excalidraw", .opened_at = 5, .element_count = 0 },
        .{ .id = 2, .path = "/Desktop/a.excalidraw", .opened_at = 4, .element_count = 0 },
        .{ .id = 3, .path = "/Desktop/b.excalidraw", .opened_at = 3, .element_count = 0 },
    };
    const r = (try groupByDay(arena.allocator(), &rows, 5, utcDay))[0].rows;
    try std.testing.expectEqualStrings("Documents", r[0].dir.?);
    try std.testing.expectEqualStrings("Desktop", r[1].dir.?);
    try std.testing.expect(r[2].dir == null);
}

test "build: active row, row error, banner, title" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const now = std.Io.Clock.real.now(store.io()).toSeconds();
    const rows = [_]FileRecord{.{ .id = 1, .path = "/d/a.excalidraw", .opened_at = now, .element_count = 0 }};
    const vm = try build(arena.allocator(), &rows, .{ .path = "/d/a.excalidraw", .row = "/d/a.excalidraw" }, .{ .row = "/d/a.excalidraw", .msg = "disk full" }, true, now);
    try std.testing.expectEqualStrings("a.excalidraw", vm.title);
    try std.testing.expect(vm.sections[0].rows[0].active);
    try std.testing.expectEqualStrings("disk full", vm.sections[0].rows[0].err.?);
    try std.testing.expect(vm.banner == null);
    const vm2 = try build(arena.allocator(), &.{}, .{ .path = null, .row = null }, .{ .row = null, .msg = "boom" }, false, now);
    try std.testing.expectEqualStrings("Untitled", vm2.title);
    try std.testing.expectEqualStrings("boom", vm2.banner.?);
}
