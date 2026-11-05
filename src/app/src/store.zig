//! Disk + history.db. Single writer (the core thread). SQL stays private to this file.
const std = @import("std");
const Allocator = std.mem.Allocator;
// Hand-declared subset of sqlite3.h: @cImport is gone in Zig 0.17 and this keeps the file build-system independent.
const c = struct {
    pub const sqlite3 = opaque {};
    pub const sqlite3_stmt = opaque {};
    pub const SQLITE_OK = 0;
    pub const SQLITE_ROW = 100;
    pub const SQLITE_DONE = 101;
    pub extern fn sqlite3_open(path: [*:0]const u8, db: *?*sqlite3) c_int;
    pub extern fn sqlite3_close(db: *sqlite3) c_int;
    pub extern fn sqlite3_exec(db: *sqlite3, sql: [*:0]const u8, cb: ?*anyopaque, arg: ?*anyopaque, err: ?*anyopaque) c_int;
    pub extern fn sqlite3_errmsg(db: *sqlite3) [*:0]const u8;
    pub extern fn sqlite3_prepare_v2(db: *sqlite3, sql: [*:0]const u8, n: c_int, st: *?*sqlite3_stmt, tail: ?*anyopaque) c_int;
    pub extern fn sqlite3_finalize(st: *sqlite3_stmt) c_int;
    pub extern fn sqlite3_step(st: *sqlite3_stmt) c_int;
    pub extern fn sqlite3_bind_text(st: *sqlite3_stmt, idx: c_int, s: [*]const u8, n: c_int, destructor: ?*const anyopaque) c_int;
    pub extern fn sqlite3_bind_int64(st: *sqlite3_stmt, idx: c_int, v: i64) c_int;
    pub extern fn sqlite3_column_int64(st: *sqlite3_stmt, col: c_int) i64;
    pub extern fn sqlite3_column_bytes(st: *sqlite3_stmt, col: c_int) c_int;
    pub extern fn sqlite3_column_text(st: *sqlite3_stmt, col: c_int) [*]const u8;
};
const log = std.log.scoped(.store);

/// Process-wide Io for plain blocking file/time calls (callable from any thread).
pub fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub const Path = []const u8; // absolute
pub const Doc = struct {
    path: ?Path, // where the next write lands; null = allocate drafts/Untitled-N on first write
    row: ?Path, // the path the history row currently holds for this doc; null = no row yet
};
pub const FileRecord = struct { id: u64, path: Path, opened_at: i64, element_count: u32 }; // SRS 6.2

const migrations = [_][:0]const u8{
    \\CREATE TABLE IF NOT EXISTS files (
    \\  id            INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  path          TEXT NOT NULL UNIQUE,
    \\  opened_at     INTEGER NOT NULL,
    \\  element_count INTEGER NOT NULL DEFAULT 0
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_files_opened_at ON files(opened_at DESC);
};

const draft_prefix = "Untitled-";
const draft_suffix = ".excalidraw";

/// N from "Untitled-N.excalidraw", else null.
fn parseDraftN(name: []const u8) ?u32 {
    if (!std.mem.startsWith(u8, name, draft_prefix) or !std.mem.endsWith(u8, name, draft_suffix)) return null;
    const mid = name[draft_prefix.len .. name.len - draft_suffix.len];
    return std.fmt.parseInt(u32, mid, 10) catch null;
}

pub const Store = struct {
    gpa: Allocator,
    db: *c.sqlite3,
    app_data: []u8,

    pub fn open(gpa: Allocator, app_data: []const u8) !Store {
        const dir = try gpa.dupe(u8, app_data);
        errdefer gpa.free(dir);
        inline for (.{ "drafts", "logs" }) |sub| {
            const p = try std.fs.path.join(gpa, &.{ dir, sub });
            defer gpa.free(p);
            try std.Io.Dir.cwd().createDirPath(io(), p);
        }
        const db_path = try std.fmt.allocPrint(gpa, "{s}/history.db\x00", .{dir});
        defer gpa.free(db_path);
        var db: ?*c.sqlite3 = null;
        if (c.sqlite3_open(db_path[0 .. db_path.len - 1 :0].ptr, &db) != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close(d);
            return error.SqliteOpen;
        }
        var self = Store{ .gpa = gpa, .db = db.?, .app_data = dir };
        errdefer _ = c.sqlite3_close(self.db);
        try self.migrate();
        try self.reconcileDrafts();
        return self;
    }

    pub fn close(self: *Store) void {
        _ = c.sqlite3_close(self.db);
        self.gpa.free(self.app_data);
    }

    /// File first (atomic), then history. Returns the path written (gpa-owned). Idempotent for identical input.
    pub fn write(self: *Store, doc: Doc, bytes: []const u8, count: u32, now: i64) !Path {
        const dest = if (doc.path) |p| try self.gpa.dupe(u8, p) else try self.nextDraftPath();
        errdefer self.gpa.free(dest);
        try writeAtomic(self.gpa, dest, bytes);

        try self.exec("BEGIN");
        errdefer self.exec("ROLLBACK") catch {};
        if (doc.row) |row| if (!std.mem.eql(u8, row, dest)) {
            const del = try self.prepare("DELETE FROM files WHERE path = ?1");
            defer _ = c.sqlite3_finalize(del);
            bindText(del, 1, dest);
            try stepDone(del);
            const upd = try self.prepare("UPDATE files SET path = ?1 WHERE path = ?2");
            defer _ = c.sqlite3_finalize(upd);
            bindText(upd, 1, dest);
            bindText(upd, 2, row);
            try stepDone(upd);
        };
        const ins = try self.prepare("INSERT INTO files(path, opened_at, element_count) VALUES(?1, ?2, ?3) " ++
            "ON CONFLICT(path) DO UPDATE SET element_count = excluded.element_count");
        defer _ = c.sqlite3_finalize(ins);
        bindText(ins, 1, dest);
        _ = c.sqlite3_bind_int64(ins, 2, now);
        _ = c.sqlite3_bind_int64(ins, 3, count);
        try stepDone(ins);
        try self.exec("COMMIT");
        return dest;
    }

    pub fn touch(self: *Store, path: Path, now: i64) !void { // upsert opened_at = now
        const st = try self.prepare("INSERT INTO files(path, opened_at, element_count) VALUES(?1, ?2, 0) " ++
            "ON CONFLICT(path) DO UPDATE SET opened_at = excluded.opened_at");
        defer _ = c.sqlite3_finalize(st);
        bindText(st, 1, path);
        _ = c.sqlite3_bind_int64(st, 2, now);
        try stepDone(st);
    }

    /// ORDER BY opened_at DESC. Paths are allocated from `gpa` (use an arena or `freeList`).
    pub fn list(self: *Store, gpa: Allocator) ![]FileRecord {
        const st = try self.prepare("SELECT id, path, opened_at, element_count FROM files ORDER BY opened_at DESC, id DESC");
        defer _ = c.sqlite3_finalize(st);
        var out: std.ArrayList(FileRecord) = .empty;
        errdefer {
            for (out.items) |r| gpa.free(r.path);
            out.deinit(gpa);
        }
        while (c.sqlite3_step(st) == c.SQLITE_ROW) {
            const n: usize = @intCast(c.sqlite3_column_bytes(st, 1));
            const p = c.sqlite3_column_text(st, 1)[0..n];
            const path = try gpa.dupe(u8, p);
            errdefer gpa.free(path);
            try out.append(gpa, .{
                .id = @intCast(c.sqlite3_column_int64(st, 0)),
                .path = path,
                .opened_at = c.sqlite3_column_int64(st, 2),
                .element_count = @intCast(c.sqlite3_column_int64(st, 3)),
            });
        }
        return out.toOwnedSlice(gpa);
    }

    pub fn freeList(gpa: Allocator, rows: []FileRecord) void {
        for (rows) |r| gpa.free(r.path);
        gpa.free(rows);
    }

    pub fn readScene(gpa: Allocator, path: Path) ![]u8 { // no db; called on the net thread
        return std.Io.Dir.cwd().readFileAlloc(io(), path, gpa, .limited(256 * 1024 * 1024));
    }

    /// 1 + max N over drafts/Untitled-N.excalidraw. Returned path is gpa-owned.
    pub fn nextDraftPath(self: *Store) !Path {
        const drafts = try std.fs.path.join(self.gpa, &.{ self.app_data, "drafts" });
        defer self.gpa.free(drafts);
        var d = try std.Io.Dir.openDirAbsolute(io(), drafts, .{ .iterate = true });
        defer d.close(io());
        var max: u32 = 0;
        var it = d.iterate();
        while (try it.next(io())) |e| {
            if (parseDraftN(e.name)) |n| max = @max(max, n);
        }
        return std.fmt.allocPrint(self.gpa, "{s}/drafts/{s}{d}{s}", .{ self.app_data, draft_prefix, max + 1, draft_suffix });
    }

    /// The drafts dir is the source of truth: every Untitled-N file gets a row (opened_at = mtime) if it lacks one.
    fn reconcileDrafts(self: *Store) !void {
        const drafts = try std.fs.path.join(self.gpa, &.{ self.app_data, "drafts" });
        defer self.gpa.free(drafts);
        var d = try std.Io.Dir.openDirAbsolute(io(), drafts, .{ .iterate = true });
        defer d.close(io());
        var it = d.iterate();
        while (try it.next(io())) |e| {
            if (e.kind != .file or parseDraftN(e.name) == null) continue;
            const st = d.statFile(io(), e.name, .{}) catch continue;
            const full = try std.fs.path.join(self.gpa, &.{ drafts, e.name });
            defer self.gpa.free(full);
            const ins = try self.prepare("INSERT OR IGNORE INTO files(path, opened_at, element_count) VALUES(?1, ?2, 0)");
            defer _ = c.sqlite3_finalize(ins);
            bindText(ins, 1, full);
            _ = c.sqlite3_bind_int64(ins, 2, st.mtime.toSeconds());
            try stepDone(ins);
        }
    }

    fn migrate(self: *Store) !void {
        try self.exec("CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)");
        var version: i64 = 0;
        {
            const sel = try self.prepare("SELECT version FROM schema_version LIMIT 1");
            defer _ = c.sqlite3_finalize(sel);
            if (c.sqlite3_step(sel) == c.SQLITE_ROW) {
                version = c.sqlite3_column_int64(sel, 0);
            } else {
                try self.exec("INSERT INTO schema_version(version) VALUES(0)");
            }
        }
        if (version > migrations.len) return error.DbTooNew;
        var i: usize = @intCast(version);
        while (i < migrations.len) : (i += 1) {
            try self.exec("BEGIN");
            errdefer self.exec("ROLLBACK") catch {};
            try self.exec(migrations[i]);
            const up = try self.prepare("UPDATE schema_version SET version = ?1");
            defer _ = c.sqlite3_finalize(up);
            _ = c.sqlite3_bind_int64(up, 1, @intCast(i + 1));
            try stepDone(up);
            try self.exec("COMMIT");
        }
    }

    fn exec(self: *Store, sql: [:0]const u8) !void {
        if (c.sqlite3_exec(self.db, sql.ptr, null, null, null) != c.SQLITE_OK) {
            log.err("sqlite: {s}", .{c.sqlite3_errmsg(self.db)});
            return error.Sqlite;
        }
    }

    fn prepare(self: *Store, sql: [:0]const u8) !*c.sqlite3_stmt {
        var st: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql.ptr, -1, &st, null) != c.SQLITE_OK) {
            log.err("sqlite prepare: {s}", .{c.sqlite3_errmsg(self.db)});
            return error.Sqlite;
        }
        return st.?;
    }
};

// SQLITE_STATIC (null destructor): the bound slice outlives the statement in every caller.
fn bindText(st: *c.sqlite3_stmt, idx: c_int, s: []const u8) void {
    _ = c.sqlite3_bind_text(st, idx, s.ptr, @intCast(s.len), null);
}

fn stepDone(st: *c.sqlite3_stmt) !void {
    if (c.sqlite3_step(st) != c.SQLITE_DONE) return error.Sqlite;
}

/// tmp + fsync + rename: the file is old or new, never partial.
fn writeAtomic(gpa: Allocator, dest: []const u8, bytes: []const u8) !void {
    const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{dest});
    defer gpa.free(tmp);
    {
        const f = try std.Io.Dir.createFileAbsolute(io(), tmp, .{});
        defer f.close(io());
        errdefer std.Io.Dir.deleteFileAbsolute(io(), tmp) catch {};
        try f.writeStreamingAll(io(), bytes);
        try f.sync(io());
    }
    try std.Io.Dir.renameAbsolute(tmp, dest, io());
}

test "parseDraftN" {
    try std.testing.expectEqual(@as(?u32, 7), parseDraftN("Untitled-7.excalidraw"));
    try std.testing.expectEqual(@as(?u32, null), parseDraftN("Untitled-x.excalidraw"));
    try std.testing.expectEqual(@as(?u32, null), parseDraftN("Untitled-7.excalidraw.tmp"));
    try std.testing.expectEqual(@as(?u32, null), parseDraftN("other.excalidraw"));
}

test "store: draft path monotonic, CRUD, repath, reconcile" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);

    var s = try Store.open(gpa, root);
    defer s.close();

    const p1 = try s.write(.{ .path = null, .row = null }, "{\"a\":1}", 1, 100);
    defer gpa.free(p1);
    const p2 = try s.write(.{ .path = null, .row = null }, "{\"a\":2}", 2, 200);
    defer gpa.free(p2);
    try std.testing.expect(std.mem.endsWith(u8, p1, "Untitled-1.excalidraw"));
    try std.testing.expect(std.mem.endsWith(u8, p2, "Untitled-2.excalidraw"));

    // rewrite same path: idempotent, count updated, still two rows
    const p1b = try s.write(.{ .path = p1, .row = p1 }, "{\"a\":3}", 5, 300);
    defer gpa.free(p1b);
    const scene = try Store.readScene(gpa, p1b);
    defer gpa.free(scene);
    try std.testing.expectEqualStrings("{\"a\":3}", scene);

    try s.touch(p2, 400);
    const rows = try s.list(gpa);
    defer Store.freeList(gpa, rows);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings(p2, rows[0].path); // newest opened_at first
    try std.testing.expectEqual(@as(u32, 5), rows[1].element_count);

    // Save As: row moves to the new path
    const target = try std.fmt.allocPrint(gpa, "{s}/saved.excalidraw", .{root});
    defer gpa.free(target);
    const moved = try s.write(.{ .path = target, .row = p1 }, "{}", 0, 500);
    defer gpa.free(moved);
    const rows2 = try s.list(gpa);
    defer Store.freeList(gpa, rows2);
    try std.testing.expectEqual(@as(usize, 2), rows2.len);
    for (rows2) |r| try std.testing.expect(!std.mem.eql(u8, r.path, p1));

    // reconcile: a draft file with no row gets one on the next open
    const orphan = try std.fmt.allocPrint(gpa, "{s}/drafts/Untitled-9.excalidraw", .{root});
    defer gpa.free(orphan);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "drafts/Untitled-9.excalidraw", .data = "{}" });
    s.close();
    s = try Store.open(gpa, root);
    const rows3 = try s.list(gpa);
    defer Store.freeList(gpa, rows3);
    var found = false;
    for (rows3) |r| found = found or std.mem.eql(u8, r.path, orphan);
    try std.testing.expect(found);
    const next = try s.nextDraftPath();
    defer gpa.free(next);
    try std.testing.expect(std.mem.endsWith(u8, next, "Untitled-10.excalidraw"));
}
