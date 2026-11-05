# Design: bridge is a doorbell, loopback is the pipe, one Zig thread writes everything

Nothing here is compiled. `zig` and `nui` are not installed, and NanoUI's API is unknown. Every NanoUI call is marked `ASSUMPTION:` and confined to `src/ui.zig`.

## Problem

The live scene sits in Excalidraw's JS heap and can be megabytes. NanoUI's bridge is the only typed channel into it, and it caps a message at 16 KiB. Even so, Zig must own file identity, every disk write, history, and the MCP endpoint (§1.1, §5). Four actors drive the file lifecycle: the user (sidebar or menu), the webview (auto-save), the MCP sidecar (WS), and failures (reload, crash, sidecar death). The shape has to give each piece of state exactly one owner while moving unbounded bytes over a channel that cannot carry them. NanoUI's API is unknown, so `src/ui.zig` is the only file that imports NanoUI, and every call in it is marked `ASSUMPTION:`.

## Usage (caller's view)

**Sidebar** (`src/ui.zig`, main thread). The sidebar only posts intents and paints a `ViewModel`. It never touches files or SQLite.
```zig
if (nui.button("New file")) mailbox.post(.new_file);                       // ASSUMPTION: nui.button
if (nui.button("Open file")) if (dialog.pickOpen(&.{ "excalidraw", "json" })) |p| mailbox.post(.{ .open = p });
for (vm.sections) |s| { nui.header(s.header); for (s.rows) |r| if (nui.row(r.label, r.active, r.err)) mailbox.post(.{ .open = r.path }); }
fn onCanvasReady() void { mailbox.post(.canvas_ready); }                     // generated bridge inbound
fn onCanvasReply(r: protocol.CanvasReply) void { mailbox.post(.{ .canvas_reply = r }); }
fn onSaveAsRequested() void { if (dialog.pickSave("Untitled.excalidraw")) |p| mailbox.post(.{ .save_as = p }); }
```
**Webview** (`web/src/canvas.ts`). Zig requests arrive on the bridge. Bytes move only over same-origin HTTP. The webview never sees a file path.
```ts
bridge.onCanvasRequest((req) => canvas.enqueue(req));             // every Zig→webview call, run one at a time
<Excalidraw excalidrawAPI={canvas.attach} onChange={canvas.onChange} UIOptions={canvas.uiOptions}>…</Excalidraw>
// inside canvas.ts, the only two outbound paths:
await putDoc(snapshot);                                           // auto-save, flush, Cmd+S, pre-swap: all one function
bridge.canvasReply({ request_id, err: null });
```
**MCP tool handler** (`mcp/src/index.ts`). Each tool is one `link.call`. Failures never throw out of a tool.
```ts
tool("add_elements", AddElements, async ({ elements }) => { await link.call("canvas.applyPatch", { create: elements }); return { ok: true, added: elements.length }; });
tool("get_scene", {}, async () => { const f = await link.call("canvas.getScene", {}); return { ok: true, elements: f.elements, appState: f.appState }; });
tool("save_scene", {}, async () => ({ ok: true, ...(await link.call("file.save", {})) }));   // { path }
```

## Module map

| Path | Owns |
|---|---|
| `build.zig` | Runs the web build, generates the `assets` module from `web/dist`, compiles the vendored `sqlite3.c`, and wires tests, including the shared WS fixture |
| `src/main.zig` | Boot: app-data paths, logging, `Store.open`, binding the listener (failure is fatal, which doubles as the single-instance lock), spawning the net and core threads, and `ui.run` |
| `src/core.zig` | **The only mutator.** `Core` (docs, active doc, pending canvas calls, MCP conns, UI error), `Event`, `Effect`, `Mailbox`. Every transition lives here. |
| `src/store.zig` | Disk and `history.db`: atomic scene write, `Untitled-N` allocation, history upsert and repath, migrations, draft reconcile. SQL stays private. |
| `src/view.zig` | Pure `ViewModel` build: `groupByDay`, `Today`/`Yesterday`/`MMM D, YYYY`, title. `localDay` is its only libc call. |
| `src/net.zig` | The loopback listener `127.0.0.1:$EXCALIDRAW_WS_PORT` (default 7411): embedded assets, `/doc/:id`, `/rpc/:id`, and the `/mcp` WS upgrade. Request guard. Thread per connection. |
| `src/protocol.zig` | The only wire contract: bridge types (NanoUI's generator input), WS envelope parse and format, the `McpMethod` table |
| `src/ui.zig` | **The only NanoUI/WKWebView importer**: window, 240px sidebar paint, webview, bridge in and out, open and save dialogs, title, close veto |
| `src/log.zig` | `std.log` override: JSON lines to `<app-data>/logs/app.log`, level from `LOG_LEVEL` |
| `web/src/main.tsx` | Mounts `<Excalidraw>`, sets `EXCALIDRAW_ASSET_PATH="/"` (fonts from loopback, no CDN egress), adds a MainMenu "Save as…" item, hides Excalidraw's own Open/Save |
| `web/src/canvas.ts` | The webview's doc state (`doc`, last saved bytes), the serial op queue, the save chain, the debounce, Cmd+S |
| `web/src/patch.ts` | Pure `resolvePatch(current, patch)`, unit-tested |
| `web/src/generated/bridge.ts` | NanoUI-generated from `src/protocol.zig`. Never hand-edited. |
| `mcp/src/index.ts` | MCP stdio server: 5 tools, zod schemas, `{ok:false,error}` wrapper |
| `mcp/src/link.ts` | WS client to Zig: lazy connect and reconnect, id→promise map, 15s timeout, ping watchdog, exit on stdin EOF |
| `mcp/test/ws-calls.jsonl` | One WS request per method. The sidecar test asserts it emits these. A Zig test (wired by `build.zig`) asserts each one parses. |

## Shape

### Ownership (data structures first)

| State | Sole owner | Everyone else |
|---|---|---|
| Live scene (elements, appState, files) | webview (Excalidraw) | Zig treats scene bytes as opaque and never parses an element |
| Which doc is open, and doc → path binding | `Core.docs` / `Core.active` | The webview holds only an opaque `DocId`. The sidebar reads the `ViewModel`. |
| Bytes on disk and `history.db` rows | the core thread, via `Store` (single writer) | The net thread *reads* scene files after core resolves the path |
| bridge `RequestId` ↔ WS id | `Core.pending[rid].origin` | The webview sees only `rid`. The sidecar sees only its uuid. |
| MCP call deadline | sidecar `link.ts` | Zig keeps no per-call timeouts |

There are two planes. The **control plane** is the generated bridge. It carries `CanvasRequest`, `CanvasReply`, `ready`, and `saveAsRequested`. Every field is fixed-size, and `err` is truncated to 1 KiB, so no scene size can reach the 16 KiB cap. The **data plane** is loopback HTTP on the asset listener: `/doc/:id` and `/rpc/:id` carry opaque bytes that Zig never parses. Zig routes the bytes and never reads them (per boundary-discipline: elements are validated in the webview, where the element model lives).

### Zig types (bodies are `@panic("not implemented")` unless pseudocode follows)
```zig
// protocol.zig: the generator input for web/src/generated/bridge.ts
pub const DocId = u32;      // issued by Core per load; never reused within a process
pub const RequestId = u32;  // issued by Core per canvas call; never reused within a process
pub const CanvasRequest = struct { request_id: RequestId, op: CanvasOp };          // Zig → webview
pub const CanvasOp = union(enum) {  // ASSUMPTION: generator supports tagged unions; else flat {kind, doc}
    load: DocId,   // GET /doc/<id>, validate, flush previous doc, swap, adopt id
    flush: DocId,  // PUT live scene to /doc/<id> now (force); error if the canvas isn't showing <id>
    apply,         // GET /rpc/<rid> → patch JSON; resolvePatch; one updateScene
    get_scene,     // PUT /rpc/<rid> ← serializeAsJSON(...)        (always JSON)
    screenshot,    // PUT /rpc/<rid> ← JSON.stringify({ svg })     (always JSON)
};
pub const CanvasReply = struct { request_id: RequestId, err: ?[]const u8 };        // ok ⇔ err == null
// payload-less webview → Zig bridge calls: canvas.ready, canvas.saveAsRequested
pub const McpMethod = enum { apply_patch, get_scene, screenshot, save };  // "canvas.applyPatch" "canvas.getScene" "canvas.screenshot" "file.save"
pub const McpCall = struct { ws_id: []const u8, method: McpMethod, params: []const u8 };  // params = raw JSON
pub fn parseMcpCall(gpa: Allocator, frame: []const u8) error{ BadEnvelope, OutOfMemory }!McpCall;
pub fn mcpOk(gpa: Allocator, ws_id: []const u8, raw_result: []const u8) ![]u8;   // {"id":…,"result":<raw>}
pub fn mcpErr(gpa: Allocator, ws_id: []const u8, msg: []const u8) ![]u8;        // {"id":…,"error":"…"}

// store.zig
pub const Path = []const u8;                // absolute; owned by the Core allocator
pub const Doc = struct {
    path: ?Path,  // where the next write lands; null = allocate drafts/Untitled-N on first write
    row: ?Path,   // the path the history row currently holds for this doc; null = no row yet
};
pub const FileRecord = struct { id: u64, path: Path, opened_at: i64, element_count: u32 };   // SRS §6.2
pub const Store = struct {
    pub fn open(gpa: Allocator, app_data: []const u8) !Store;   // mkdir drafts/ logs/; migrate; reconcileDrafts()
    /// File first (atomic), then history. Returns the path written. Idempotent for identical input.
    pub fn write(self: *Store, doc: Doc, bytes: []const u8, count: u32, now: i64) !Path;
    pub fn touch(self: *Store, path: Path, now: i64) !void;     // upsert opened_at = now
    pub fn list(self: *Store, gpa: Allocator) ![]FileRecord;    // ORDER BY opened_at DESC
    pub fn readScene(gpa: Allocator, path: Path) ![]u8;         // no db; called on the net thread
};

// core.zig
pub const ConnId = u32;
pub const Origin = union(enum) { user, quit, mcp: struct { conn: ConnId, ws_id: []u8, method: McpMethod } };
const Pending = struct { op: CanvasOp, origin: Origin, params: ?[]u8 = null, result: ?[]u8 = null };
pub const UiError = struct { row: ?Path, msg: []const u8 };        // row = null → banner
pub fn Slot(comptime T: type) type { return struct { value: T = undefined, done: std.Thread.ResetEvent = .{} }; }
pub const DocSource = union(enum) { unknown, blank, file: Path };
pub const WriteOutcome = union(enum) { ok, unknown_doc, failed: []const u8 };
pub const Event = union(enum) {
    new_file, open: Path, save_as: Path, quit,                                   // ui.zig
    canvas_ready, canvas_reply: CanvasReply,                                     // ui.zig (bridge)
    doc_read: struct { doc: DocId, out: *Slot(DocSource) },                      // net.zig
    doc_write: struct { doc: DocId, bytes: []u8, count: u32, out: *Slot(WriteOutcome) },
    rpc_params: struct { req: RequestId, out: *Slot(?[]u8) },
    rpc_result: struct { req: RequestId, bytes: []u8, out: *Slot(bool) },
    mcp_open: ConnId, mcp_call: struct { conn: ConnId, call: McpCall }, mcp_pong: ConnId, mcp_closed: ConnId,
};
pub const Effect = union(enum) {
    canvas: CanvasRequest, view: view.ViewModel, ws_send: struct { conn: ConnId, frame: []u8 },
    ws_ping: ConnId, ws_close: ConnId, exit,
};
pub const Core = struct {
    docs: std.AutoHashMapUnmanaged(DocId, Doc),            // every doc issued; never pruned (see tradeoffs)
    active: DocId,                                          // set only by a successful load reply
    pending: std.AutoArrayHashMapUnmanaged(RequestId, Pending),   // capacity 64 → "busy"
    conns: std.AutoHashMapUnmanaged(ConnId, i64),           // last pong, ms
    canvas_ready: bool, err: ?UiError, quit_at: ?i64, next_id: u32,
    effects: std.ArrayListUnmanaged(Effect),
    pub fn init(gpa: Allocator, store: *Store) !Core;       // active = issue(.{ .path = null, .row = null })
    pub fn handle(self: *Core, ev: Event) void;             // the only mutator; core thread only
    pub fn tick(self: *Core, now_ms: i64) void;             // ping every 5s; close conns silent >15s; quit deadline
    pub fn takeEffects(self: *Core) []Effect;               // main.zig dispatches → ui / net
};
pub const Mailbox = struct {                                // Mutex + Condition + ArrayList
    pub fn post(self: *Mailbox, ev: Event) void;            // any thread, never blocks on core work
    pub fn wait(self: *Mailbox, timeout_ms: u32) ?Event;    // core thread
};

// view.zig: pure except localDay
pub const ViewModel = struct { title: []const u8, enabled: bool, banner: ?[]const u8, sections: []Section }; // sections empty → "No files yet"
pub const Section = struct { header: []const u8, rows: []Row };
pub const Row = struct { path: Path, label: []const u8, active: bool, err: ?[]const u8 };
pub fn build(gpa: Allocator, rows: []const FileRecord, active: Doc, err: ?UiError, enabled: bool, now: i64) !ViewModel;
pub fn groupByDay(gpa: Allocator, rows: []const FileRecord, now: i64, dayOf: *const fn (i64) i32) ![]Section;
pub fn localDay(unix_s: i64) i32;   // localtime_r per timestamp (DST-correct); epoch-day in local tz

// ui.zig: ASSUMPTION everywhere. The public surface is these three calls.
pub fn run(gpa: Allocator, url: []const u8, mailbox: *core.Mailbox) !void;  // main thread; blocks until exit
pub fn publish(vm: view.ViewModel) void;           // any thread → main-thread repaint + window title
pub fn sendCanvas(req: protocol.CanvasRequest) void;   // any thread → bridge emit on main thread

// net.zig
pub const Net = struct {
    pub fn listen(gpa: Allocator, port: u16, mailbox: *core.Mailbox) !Net;   // error.AddressInUse → fatal dialog
    pub fn serve(self: *Net) void;                              // accept loop; one thread per connection
    pub fn send(self: *Net, conn: ConnId, frame: []const u8) void;   // per-conn write mutex
    pub fn ping(self: *Net, conn: ConnId) void;
    pub fn close(self: *Net, conn: ConnId) void;
};
// guard(): Host must be 127.0.0.1:<port> (blocks DNS rebinding); /doc and /rpc require header `X-Excalibre: 1`
// (a cross-origin page can't send it without a preflight we never grant); /mcp rejects any `Origin`
// header (browsers always send one on WS; node `ws` does not).
// Graft from candidate 2: /doc and /rpc also require `Authorization: Bearer <token>`. Zig makes the token at boot
// and passes it to the page in the URL hash, so another local process on 127.0.0.1 cannot read or write scenes.
```

### Wire contracts (TS side)
```ts
// web/src/generated/bridge.ts: EXPECTED generator output (ASSUMPTION on encoding of union(enum))
export type CanvasOp = { load: number } | { flush: number } | { apply: {} } | { get_scene: {} } | { screenshot: {} };
export interface CanvasRequest { request_id: number; op: CanvasOp }
export interface CanvasReply { request_id: number; err: string | null }
export declare const bridge: { onCanvasRequest(cb: (r: CanvasRequest) => void): void;
  canvasReply(r: CanvasReply): void; canvasReady(): void; saveAsRequested(): void };
// Data plane (same origin, header X-Excalibre: 1):
//  GET /doc/:id → 200 scene | 404        PUT /doc/:id (X-Element-Count) → 204 | 409 unknown doc | 500 msg
//  GET /rpc/:rid → 200 patch | 404       PUT /rpc/:rid → 204 | 404
// WS /mcp (§7.3 envelope): → {id, method, params}   ← {id, result} | {id, error}. Zig sends ping frames every 5s.
//  canvas.applyPatch {create?,update?,delete?} → {} · canvas.getScene {} → .excalidraw JSON
//  canvas.screenshot {} → {svg} · file.save {} → {path}

// web/src/canvas.ts
type Snapshot = { readonly doc: number; readonly bytes: string; readonly count: number; readonly dirty: boolean };
export function attach(api: ExcalidrawImperativeAPI): void;   // store api, bridge.canvasReady()
export function onChange(): void;                             // debounce 700ms → putDoc(takeSnapshot()) if dirty
export function enqueue(req: CanvasRequest): void;            // queue = queue.then(() => run(req))
function takeSnapshot(): Snapshot | null;  // the ONLY constructor: reads doc + scene in one sync step
function putDoc(s: Snapshot, force?: boolean): Promise<void>; // the ONLY writer: chained, ordered, PUT /doc/<s.doc>
// web/src/patch.ts
export type Patch = { create?: ElementSkeleton[]; update?: ({ id: string } & Partial<ExcalidrawElement>)[]; delete?: string[] };
export function resolvePatch(current: readonly ExcalidrawElement[], p: Patch): ExcalidrawElement[]; // throws PatchError; pure
```
MCP tool schemas (`mcp/src/index.ts`, zod). FR-M7: validate inside the handler with `safeParse`, so malformed input returns `{ok:false,error}`.
```ts
const Element = z.object({ type: z.string(), id: z.string().optional() }).passthrough();
add_elements: { elements: z.array(Element).min(1) }                 → { ok: true, added: n }
apply_scene:  { create: z.array(Element).optional(), update: z.array(Element.extend({ id: z.string() })).optional(),
                delete: z.array(z.string()).optional() }           → { ok: true }
get_scene: {} → { ok: true, elements, appState }   screenshot: {} → { ok: true, svg }   save_scene: {} → { ok: true, path }
any failure → { ok: false, error } with isError: true
```

### Q1: who owns the scene bytes, and how a >16 KiB scene is saved
The webview owns the live scene. Zig owns where the bytes go and is the only process that writes them. Every save, whether auto-save, flush, `save_scene`, Cmd+S, or the flush before a file switch, goes through `takeSnapshot()` then `putDoc()`:
```
webview  onChange → debounce 700ms → s = takeSnapshot()   // {doc, serializeAsJSON(getSceneElements(), appState, getFiles(), "local"), count, dirty: bytes != lastSaved}
         putDoc(s): chain = chain.catch(noop).then(() => PUT /doc/<s.doc>)   // one in flight; order = snapshot order
net      PUT → guard → mailbox.post(doc_write{doc, bytes, count, &slot}); slot.wait(); 204|409|500
core     d = docs.getPtr(doc) orelse → .unknown_doc
         path = store.write(d.*, bytes, count, now) catch |e| { d.path = d.row; err = {d.row, msg}; → .failed }
         d.path = d.row = path; clear err for this row; publish view                → .ok
store.write: dest = doc.path orelse nextDraftPath()     // 1 + max N over drafts/Untitled-(N).excalidraw
             dir.atomicFile(dest) → write → file.sync() → finish()   // rename: the file is old or new, never partial
             BEGIN; if row and row != dest: DELETE path=dest; UPDATE path=dest WHERE path=row;
                    INSERT (dest, now, count) ON CONFLICT(path) DO UPDATE SET element_count=count; COMMIT
```
Because the snapshot is captured synchronously, a snapshot of doc A can never contain doc B's elements. Because the chain is serial, an older snapshot can never land after a newer one.
Graft from candidate 2: a failed PUT leaves `lastSaved` unchanged, so the snapshot stays dirty. `canvas.ts` re-arms a 5s retry timer after a failure, and Core shows the row error until a write succeeds (NFR-6, no silent loss).

### Q2: MCP request → bridge request → back
```
sidecar  id = uuid; pending[id] = {resolve, timer 15s}; ws.send({id, method, params})
net      frame → protocol.parseMcpCall → post(mcp_call{conn, call})        // bad envelope → mcpErr on the spot
core     if !canvas_ready → ws_send(mcpErr "canvas not ready");  if pending.count ≥ 64 → "busy"
         rid = next_id++; pending[rid] = {op: opFor(method), origin: .mcp{conn, ws_id, method}, params}
         effects += .canvas{rid, op}                       // opFor(.save) = .flush(active)
webview  run(req): GET /rpc/<rid> (apply) · work · PUT /rpc/<rid> (get_scene/screenshot) · bridge.canvasReply
core     p = pending.fetchRemove(rid) orelse { log.debug("late reply"); return }   // a reply is consumed exactly once
         route(p, reply): .mcp → if !conns.contains(conn) drop
                          err → mcpErr; apply → mcpOk "{}"; get_scene/screenshot → mcpOk(p.result raw)
                          save → mcpOk {"path": docs[p.op.flush].path.?}  // the PUT finished before the reply was sent
```
Request ids live in two places only: the sidecar's map (uuid) and `Core.pending` (rid → origin carrying the uuid).
- **Timeout**: the sidecar fails the tool after 15s with "timed out; the change may still apply, call get_scene". Zig has no timers per call. A late reply is consumed and dropped at `route`.
- **Webview reload**: the new page sends `canvas.ready`. Core routes "canvas reloaded" to every pending origin, clears the table, then sends `load(active)`. Startup takes the same path. Ids are never reused, so a late reply from the old page misses.
- **Sidecar death**: socket EOF → `mcp_closed` → remove the conn. In-flight webview work completes, and its reply is dropped at `route`. Zig's `tick` also closes any conn with no pong for 15s.
- **Zig death**: the sidecar gets close, or no ping for 15s → `terminate()` → reject every pending call "app disconnected". It reconnects with 0.5→5s backoff and keeps serving stdio. Calls made while disconnected fail fast.

### Q3: file lifecycle, with one owner and idempotent transitions
All transitions live in `Core.handle`. `Store.write` is the only way a draft comes into existence.
```
new_file      id = issue({null,null}); call(load id); call(flush id)   // flush materializes Untitled-N + row now (FR-F1)
open(p)       if docs[active].path == p { store.touch(p); publish; return }      // re-click = touch only
              id = issue({p,p}); call(load id)                    // active switches ONLY on load ok (NFR-7: keep prior)
canvas_reply  load ok → active = id; if path: store.touch(path)    load err → banner, active unchanged
save_as(p)    docs[active].path = p; call(flush active)             // write lands at p; row moves after the file exists
startup       active = issue({null,null}) (scratch, title "Untitled"); load on canvas.ready
              first write materializes a draft, so a fresh install still shows "No files yet" (FR-S2)
quit          quit_at = now+2s; call(flush active)  → reply or deadline → effects += .exit
```
Writes are accepted for **any issued doc**. That is safe because the webview writes a non-active doc only once: the final flush of doc A happens inside `load B`, before the swap, and it is awaited before the reply. A failed load never swaps, so it never writes. Retries are safe. Re-running `open`, `save_as` to the same path, `flush`, `touch`, reconcile, and migrations each converge to the same state.

The rule for crashes is that the file is written first, then SQLite:
- Crash after the rename, before the INSERT, for a new draft: at startup, `reconcileDrafts()` runs `INSERT OR IGNORE` with `opened_at = mtime` for every `drafts/Untitled-N.excalidraw` that has no row. The drafts directory is the source of truth for drafts. History is an index derived from it.
- Crash mid-write: the file is either the old or the new version (rename). The stray tmp file is harmless.
- Crash after a Save As write, before the repath: the file at P is intact, and history still shows the draft, which is a few ms older. The history move is lost. Data is not (accepted, see Tradeoffs).
- A failed write to a Save As target: `d.path = d.row` reverts, so auto-save keeps writing where the row points, and the error is shown on the row.

### Q4: `apply_scene` while the user draws
The patch is resolved **in the webview against the live scene, inside one synchronous JS task**. No pointer event can run between the read and the `updateScene`. The sidecar and Zig never build an element array, so there is no read-modify-write over a stale `get_scene`.
```ts
// run({apply}): const p = JSON.parse(await getRpc(rid));                       ← the only await, before the read
//   const next = resolvePatch(api.getSceneElementsIncludingDeleted(), p);     ← same task from here
//   api.updateScene({ elements: next, captureUpdate: CaptureUpdateAction.IMMEDIATELY }); // one undo step
function resolvePatch(cur, p) {
  // each id in at most one of create/update/delete, else PatchError. All checks happen before any write → atomic.
  const m = new Map(cur.map((e) => [e.id, e]));        // Map keeps z-order. New ids are appended on top.
  for (id of p.delete ?? []) if (m.get(id) && !m.get(id).isDeleted) m.set(id, bump({ ...m.get(id), isDeleted: true })); // missing id: no-op
  for (u of p.update ?? []) { const e = m.get(u.id); if (!e || e.isDeleted) throw new PatchError(`update: no element ${u.id}`);
                              m.set(u.id, bump({ ...e, ...u, id: e.id, type: e.type })); }       // type is immutable
  for (c of convertToExcalidrawElements(p.create ?? [], { regenerateIds: false })) m.set(c.id, bump(c, m.get(c.id))); // upsert
  return [...m.values()];   // bump(): version+1, new versionNonce, updated=now. Without it, dirty detection misses the change.
}
```
Graft from candidate 2: `resolvePatch` also returns `warnings` (a `delete` of an unknown id, a `create` that upserted an existing id). The reply to `apply_scene` becomes `{ok:true, warnings?}`, and `add_elements` reports `added` as the count of genuinely new ids.
After an apply, the change is auto-saved like any user edit. Ops run serially in the webview queue, so an apply can never interleave with a `load`. `load` calls `history.clear()` so that undo can't pull the previous file's elements into this one.

## SRS gaps and inconsistencies this design resolved
1. §7.3 says "Zig pings, the sidecar exits if no *pong*", but the sidecar is the side that receives pings. Resolution: the sidecar watches for pings, and Zig watches for pongs, both with a 15s window.
2. §11 says "Zig kills the child", but FR-M1 runs over stdio, and a stdio MCP server is spawned by the AI client, so Zig has no child. Resolution: the sidecar's process lifetime is its stdin (EOF → exit), and the heartbeat governs only the WS link. If the sidecar exited, as §7.3 literally says, the AI client would mark the server dead whenever the app is closed.
3. §7.1 `scene.changed {elements, appState}` and AGENTS rule 7 ("send patches") contradict NFR-3. A full scene can't fit in 16 KiB, and Zig-side patches would need an element model in Zig (§1.1). Resolution: the loopback data plane.
4. §7.1 has no save message, but FR-M6 needs one. Resolution: a `file.save` WS method that Core handles as a `flush` plus the path.
5. §7.1 `loadScene {path}` becomes `load {doc}`. The webview never learns a path, which is a stronger form of §5.
6. §11 "pass the full array from apply_scene" contradicts FR-M3's patch input. Resolution: the full array is built in the webview.
7. FR-S2's empty state contradicts "Zig always owns an active file". Resolution: a scratch doc that materializes on its first write. This also explains DoD 4 ("the file appears in history after the save").
8. FR-F1 "next unused N" contradicts §10 "monotonic". Resolution: N = 1 + the maximum N in `drafts/`, which is monotonic unless the user deletes the highest-numbered file outside the app.
9. §7.2 success shapes lack `ok`. Resolution: every success adds `ok: true`, so `ok` is a reliable discriminant (FR-M7).
10. §6.2 `ActiveFile` timestamps and `is_draft` have no consumer, because the dirty indicator is out of scope. Resolution: they are replaced by `Doc {path,row}`, and `is_draft` is derivable from the path.
11. FR-F5 names a menu but none is specified. Resolution: an Excalidraw `MainMenu.Item` (a known API), not an assumed NanoUI menu. Cmd+S is a webview keydown that calls `putDoc(takeSnapshot(), true)` with no Zig round trip.
12. The SRS doesn't say whether the last file reopens at startup. Resolution: always start with scratch, because DoD 2 reopens "via the sidebar".

## Tradeoffs accepted
- We accept one extra loopback hop per MCP payload (`/rpc`) in exchange for a bridge that cannot overflow at any scene size.
- We accept that a wedged webview means nothing gets saved, in exchange for Zig having no element model and never holding a second copy of the scene.
- We accept that assets and WS share port 7411, so a bind failure is fatal, in exchange for one listener and a free single-instance lock, which makes Core truly the only writer.
- We accept having no Zig-side call timeouts. A wedged canvas fills the 64-slot table and returns "busy" until the page reloads. In exchange there is no sweeper, and only one party (the sidecar) owns deadlines.
- We accept losing the *history move* if the app crashes between the Save As write and the SQLite repath, in exchange for never having a row that points at a missing file.
- We accept last-writer-wins per element when an agent patches an element the user is dragging right now.
- We accept that `create` upserts by id. An agent retry with ids is idempotent, but an agent can overwrite an element by "creating" it.
- We accept that `docs` is never pruned (a path string per open) in exchange for having no liveness rules.
- We accept that fsync runs inline on the core thread, so MCP calls queue for milliseconds behind a write. The UI thread never waits (NFR-4).

## Alternatives considered
- **Chunked bridge** (frames of ≤16 KiB with seq and reassembly). Every message type picks up chunking and partial-failure states on both sides. It is HTTP reinvented over a worse channel. Shallow, and it leaks into everything.
- **Zig holds the canonical scene, and the webview sends diffs.** This needs Excalidraw's element model and merge logic in Zig, which §1.1 rules out in spirit and which would be large.
- **Webview as a second WS client of Zig** (relay MCP frames verbatim). It deletes `/rpc`, but it creates a second command transport into the webview next to the bridge (two ways to do one task), and most traffic would bypass the generated bridge.
- **Mutex-guarded `Core` called from every thread.** Less code than a mailbox, but the main thread would block behind an fsync held by an HTTP thread (NFR-4), and lock order across net and ui threads is easy to break.

## Synthesis decision

Two runners designed independently: candidate 1 on `opus` (xhigh) and candidate 2 on the session model. No cross-judge ran. The judge must come from a non-Claude family, and the only non-Claude pool entry maps to the session model, which is Claude. I picked the base alone.

Both candidates converged on the same core: the bridge carries small control messages, loopback HTTP carries all scene bytes, one Zig core thread owns every write, `apply_scene` merges in the webview in one synchronous turn, and the sidecar lives and dies by stdin instead of the heartbeat. That convergence is strong evidence for those choices.

They split on who holds the scene. Candidate 1 leaves it in the webview. Candidate 2 keeps a second copy in Zig with a revision counter, plus a FIFO broker and an epoch/gen scheme.

**Base: candidate 1.** It has one owner per piece of state and no second copy of the scene to keep in sync. Its `DocId`, which is never reused, already does the job of candidate 2's `gen`. The cost is losing up to 700 ms of edits if the webview crashes. Candidate 2's copy would recover those, but it adds a Broker, a revision counter, and a second ingress for pushes and pulls.

**Grafted from candidate 2:**
- A per-boot bearer token on `/doc` and `/rpc`.
- A 5s retry after a failed write.
- `warnings` on patch results.
- The open questions on sidecar reconnect and on the last-writer-wins rule for `update`.

**Rejected from candidate 2:**
- The Zig-held scene copy.
- The FIFO broker.
- Reopening the last file at launch (kept as an open question below).

## Open questions and risks

- Do you accept the deviation from SRS §7.3 and §11? The sidecar would live and die by stdin and reconnect after a missed heartbeat, instead of exiting. Both candidates reached this independently because the MCP host spawns the sidecar, so Zig has no child to kill.
- Should launch reopen the most recent file (candidate 2) or start on a scratch doc (this design)? The SRS does not say.
- Is last-writer-wins per field acceptable when an agent patches an element the user is dragging? The alternative is a version precondition on `update`.
- Can NanoUI's generated bridge push Zig→JS? If it can't, should `ui.zig` expose `nextCanvasRequest()` as a JS-awaited long-poll? The rest of the design is unchanged either way.
- Does NanoUI offer main-thread dispatch from other threads, and a close veto for the quit flush? If not, is losing ≤700 ms of edits on Cmd+Q acceptable?
- Does NanoUI's own asset handler (§11 "Zig's static asset handler") conflict with our listener, or should we keep our own std.http server as sketched?
- Does WKWebView over `http://127.0.0.1` need `NSAllowsLocalNetworking` in Info.plist (ATS)?
- Does the MCP TS SDK's own zod validation pre-empt the handler, so it returns a JSON-RPC error instead of `{ok:false}`? If so, should we use the low-level `Server.setRequestHandler(CallTool)`?
- Which `@excalidraw/excalidraw` pin should we use? The answer decides `CaptureUpdateAction` vs `storeAction`, the default for `regenerateIds`, and whether `serializeAsJSON("local")` filters deleted files.
- Should deleting a container also tombstone its bound text (`containerId`)? FR-M3 says only "expected final scene".
- `std.http` WebSocket and `AtomicFile` APIs move between Zig releases. Can we pin the Zig version in M1?

## Red-flag screen
- **Shallow module**: no. Core is reached by `post` and `handle`. ui is 3 calls, Store is 5, and net is 5. Each hides threads, SQL, atomics, or NanoUI.
- **Information leakage**: no. Wire types live only in `protocol.zig`. Paths never reach JS. SQL is private to store.
- **Split ownership**: no. Each row in the ownership table has one writer.
- **Two ways**: no. There is one save path (`putDoc`), one draft creator (`Store.write`), and one reply path (`canvasReply`).
- **Hand-synced lists**: bridge types are generated, and the WS methods are pinned by the shared `ws-calls.jsonl` test on both sides. The route strings `/doc` and `/rpc` appear in both `net.zig` and `canvas.ts`, and only the integration test guards them (residual).
- **Pass-through**: `ui.sendCanvas` adds a thread hop and a bridge adaptation, so it isn't a forwarder.

## Next implementation step

Install `zig` and `nui`, run `nui start excalidraw-client` (M1), and replace the three `ASSUMPTION:` calls in `src/ui.zig` with the real API. First check whether the generated bridge can push Zig to JS and whether WKWebView loads `http://127.0.0.1`. Both change `ui.zig` only. Write `web/src/patch.ts` and `src/view.zig` in parallel, since both are pure and need no toolchain beyond Node and Zig.
