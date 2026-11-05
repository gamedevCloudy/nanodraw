//! The only wire contract: bridge types (NanoUI generator input), WS envelope parse/format.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const DocId = u32; // issued by Core per load; never reused within a process
pub const RequestId = u32; // issued by Core per canvas call; never reused within a process

pub const CanvasOp = union(enum) { // ASSUMPTION: generator supports tagged unions; else flat {kind, doc}
    load: DocId,
    flush: DocId,
    apply,
    get_scene,
    screenshot,
};
pub const CanvasRequest = struct { request_id: RequestId, op: CanvasOp }; // Zig -> webview
pub const CanvasReply = struct { request_id: RequestId, err: ?[]const u8 }; // ok <=> err == null

pub const McpMethod = enum { apply_patch, get_scene, screenshot, save };
pub const McpCall = struct { ws_id: []const u8, method: McpMethod, params: []const u8 }; // params = raw JSON; both gpa-owned

const method_names = [_]struct { []const u8, McpMethod }{
    .{ "canvas.applyPatch", .apply_patch },
    .{ "canvas.getScene", .get_scene },
    .{ "canvas.screenshot", .screenshot },
    .{ "file.save", .save },
};

pub fn parseMcpCall(gpa: Allocator, frame: []const u8) error{ BadEnvelope, OutOfMemory }!McpCall {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, frame, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadEnvelope,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.BadEnvelope;
    const obj = parsed.value.object;
    const id = obj.get("id") orelse return error.BadEnvelope;
    const name = obj.get("method") orelse return error.BadEnvelope;
    if (id != .string or name != .string) return error.BadEnvelope;
    const method = for (method_names) |m| {
        if (std.mem.eql(u8, m[0], name.string)) break m[1];
    } else return error.BadEnvelope;

    const ws_id = try gpa.dupe(u8, id.string);
    errdefer gpa.free(ws_id);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    if (obj.get("params")) |p| try writeValue(&list, gpa, p) else try list.appendSlice(gpa, "{}");
    return .{ .ws_id = ws_id, .method = method, .params = try list.toOwnedSlice(gpa) };
}

/// {"id":…,"result":<raw>}
pub fn mcpOk(gpa: Allocator, ws_id: []const u8, raw_result: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    try list.appendSlice(gpa, "{\"id\":");
    try appendQuoted(&list, gpa, ws_id);
    try list.appendSlice(gpa, ",\"result\":");
    try list.appendSlice(gpa, raw_result);
    try list.append(gpa, '}');
    return list.toOwnedSlice(gpa);
}

/// {"id":…,"error":"…"}
pub fn mcpErr(gpa: Allocator, ws_id: []const u8, msg: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    try list.appendSlice(gpa, "{\"id\":");
    try appendQuoted(&list, gpa, ws_id);
    try list.appendSlice(gpa, ",\"error\":");
    try appendQuoted(&list, gpa, msg);
    try list.append(gpa, '}');
    return list.toOwnedSlice(gpa);
}

/// A JSON string literal (quoted, escaped). Extra helper for core's `{"path":…}` reply.
pub fn quote(gpa: Allocator, s: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    try appendQuoted(&list, gpa, s);
    return list.toOwnedSlice(gpa);
}

fn appendQuoted(list: *std.ArrayList(u8), gpa: Allocator, s: []const u8) Allocator.Error!void {
    try list.append(gpa, '"');
    for (s) |ch| switch (ch) {
        '"' => try list.appendSlice(gpa, "\\\""),
        '\\' => try list.appendSlice(gpa, "\\\\"),
        '\n' => try list.appendSlice(gpa, "\\n"),
        '\r' => try list.appendSlice(gpa, "\\r"),
        '\t' => try list.appendSlice(gpa, "\\t"),
        0...8, 11, 12, 14...31 => {
            var b: [6]u8 = undefined;
            try list.appendSlice(gpa, std.fmt.bufPrint(&b, "\\u{x:0>4}", .{ch}) catch unreachable);
        },
        else => try list.append(gpa, ch),
    };
    try list.append(gpa, '"');
}

fn writeValue(list: *std.ArrayList(u8), gpa: Allocator, v: std.json.Value) Allocator.Error!void {
    switch (v) {
        .null => try list.appendSlice(gpa, "null"),
        .bool => |b| try list.appendSlice(gpa, if (b) "true" else "false"),
        .integer, .float => {
            var b: [64]u8 = undefined;
            const s = switch (v) {
                .integer => |i| std.fmt.bufPrint(&b, "{d}", .{i}),
                .float => |f| std.fmt.bufPrint(&b, "{d}", .{f}),
                else => unreachable,
            } catch unreachable; // 64 bytes fit any i64/f64 in {d}; non-finite floats are not valid JSON input
            try list.appendSlice(gpa, s);
        },
        .number_string => |s| try list.appendSlice(gpa, s),
        .string => |s| try appendQuoted(list, gpa, s),
        .array => |a| {
            try list.append(gpa, '[');
            for (a.items, 0..) |item, i| {
                if (i > 0) try list.append(gpa, ',');
                try writeValue(list, gpa, item);
            }
            try list.append(gpa, ']');
        },
        .object => |o| {
            try list.append(gpa, '{');
            var it = o.iterator();
            var first = true;
            while (it.next()) |e| {
                if (!first) try list.append(gpa, ',');
                first = false;
                try appendQuoted(list, gpa, e.key_ptr.*);
                try list.append(gpa, ':');
                try writeValue(list, gpa, e.value_ptr.*);
            }
            try list.append(gpa, '}');
        },
    }
}

test "parseMcpCall round trip" {
    const gpa = std.testing.allocator;
    const call = try parseMcpCall(gpa, "{\"id\":\"u-1\",\"method\":\"canvas.applyPatch\",\"params\":{\"create\":[{\"type\":\"rectangle\",\"x\":1.5,\"t\":\"a\\\"b\"}],\"delete\":[]}}");
    defer gpa.free(call.ws_id);
    defer gpa.free(call.params);
    try std.testing.expectEqualStrings("u-1", call.ws_id);
    try std.testing.expectEqual(McpMethod.apply_patch, call.method);
    // re-parse the emitted params: must be valid JSON with the same content
    const re = try std.json.parseFromSlice(std.json.Value, gpa, call.params, .{});
    defer re.deinit();
    const el = re.value.object.get("create").?.array.items[0].object;
    try std.testing.expectEqualStrings("rectangle", el.get("type").?.string);
    try std.testing.expectEqualStrings("a\"b", el.get("t").?.string);

    const ok = try mcpOk(gpa, call.ws_id, call.params);
    defer gpa.free(ok);
    const okp = try std.json.parseFromSlice(std.json.Value, gpa, ok, .{});
    defer okp.deinit();
    try std.testing.expectEqualStrings("u-1", okp.value.object.get("id").?.string);

    const er = try mcpErr(gpa, "x\"y", "bad\nthing");
    defer gpa.free(er);
    const erp = try std.json.parseFromSlice(std.json.Value, gpa, er, .{});
    defer erp.deinit();
    try std.testing.expectEqualStrings("bad\nthing", erp.value.object.get("error").?.string);
}

test "parseMcpCall rejects bad envelopes and defaults params" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.BadEnvelope, parseMcpCall(gpa, "not json"));
    try std.testing.expectError(error.BadEnvelope, parseMcpCall(gpa, "{\"id\":\"1\",\"method\":\"nope\"}"));
    try std.testing.expectError(error.BadEnvelope, parseMcpCall(gpa, "{\"id\":1,\"method\":\"file.save\"}"));
    const c = try parseMcpCall(gpa, "{\"id\":\"1\",\"method\":\"file.save\"}");
    defer gpa.free(c.ws_id);
    defer gpa.free(c.params);
    try std.testing.expectEqualStrings("{}", c.params);
}
