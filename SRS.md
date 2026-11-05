# SRS handoff: Excalidraw Zig client (MVP)

Document type: Software requirements specification and coding agent handoff
Target: Autonomous coding agent (Claude Code, Codex, Cursor)
Scope: MVP only. V1 and later features are out of scope.
Companion files to generate: `FEATURES.md`, `AGENTS.md` (see §12)

---

## 1. Project overview

Build a desktop Excalidraw client with:
- A native sidebar (NanoUI, Zig) showing file history grouped by day
- A central canvas (embedded Excalidraw in the system webview)
- An MCP server so AI agents can create and edit diagrams programmatically

The app is a single Zig binary (NanoUI shell and embedded webview) plus a sidecar MCP server process.

### 1.1 Fixed architectural decisions

These are settled. Do not reopen them.

| Decision | Rationale |
|---|---|
| Do NOT reimplement Excalidraw in Zig. | The element model, arrow binding, and text wrapping take thousands of lines. Embed it in the webview. |
| The sidebar is native NanoUI. | Low latency, testable offscreen, no second JS runtime for the sidebar. |
| The canvas is embedded React and `@excalidraw/excalidraw`. | The full tool set, undo/redo, and export come with it. |
| The Zig shell owns the active file state. | One source of truth for the sidebar and MCP. React does not track file identity. |
| The MCP server is a separate process (Python or TS). | Reuses existing Excalidraw MCP tooling and isolates it from Zig rebuilds. |
| Auto-save is the default. Manual save flushes immediately. | Removes the "lost work" class of bug. |

---

## 2. Scope

### 2.1 In scope (build this)

#### File management
- New file (auto-named `Untitled-N.excalidraw`, stored in `<app-data>/drafts/`)
- Open from sidebar history
- Open from disk (native file picker)
- Auto-save (debounced 500ms to 1s) to the current path
- Save As (native dialog, then migrate the path and update history)
- File history persisted in SQLite
- Sidebar grouped by day (grouping happens at read time)

#### Canvas
- All native Excalidraw tools (shapes, arrows, text, freehand, eraser, frames, laser)
- Undo/redo, zoom, pan (built into Excalidraw)
- Export through Excalidraw's own menu (PNG, SVG, `.excalidraw`)

#### Sidebar
- "New file" button
- "Open file" button
- Scrollable history with date section headers
- Active file highlight

#### MCP tools
- `add_elements`, `apply_scene`, `get_scene`, `screenshot`, `save_scene`

#### Window
- Fixed split: sidebar and canvas
- Title shows the active file name

### 2.2 Out of scope (do NOT build)

- Rename, delete, duplicate, pin, search, thumbnails, context menus
- Tabs, file watcher, cloud sync, collab, plugins, libraries, settings panel, templates
- Resizable split, keyboard shortcuts (except Cmd+S as a force-flush), dirty indicator
- MCP `list_files`, `open_file`, `create_file`, `query_elements`, `export_scene`
- Windows and Linux (the MVP targets macOS WKWebView only)

If a requirement is not in §3, it does not exist for this build. Do not add nice-to-haves.

---

## 3. Functional requirements

Each requirement has an ID and acceptance criteria.

### 3.1 File management

#### FR-F1: New file
- The user clicks "New file" in the sidebar.
- The app creates a blank scene (`elements: []`) and assigns the path `<app-data>/drafts/Untitled-N.excalidraw`, where N is the next unused integer.
- The webview loads the blank scene via `canvas.loadScene`.
- The app inserts a history row with `opened_at = now`.
- The sidebar highlights the new file.
- Acceptance: Clicking "New file" produces a blank canvas, a new sidebar row under today's date, and an auto-saved file on disk within 1s.

#### FR-F2: Open from history
- The user clicks a history row.
- The app reads `path` from SQLite and sends `canvas.loadScene { path }` to the webview.
- The webview fetches the file and calls `excalidrawAPI.updateScene({ elements })`.
- The app updates the row's `opened_at` to now, and the sidebar regroups.
- Acceptance: Clicking a history row loads that exact scene, and the row moves to the "Today" group.

#### FR-F3: Open from disk
- The user clicks "Open file", which opens the native OS file picker.
- On selection, the app reads the file path, inserts or updates the history row, and calls `canvas.loadScene`.
- Acceptance: The file picker opens. Picking a valid `.excalidraw` or `.json` file loads the scene and adds a history row.

#### FR-F4: Auto-save
- The webview fires `onChange` (debounced 500ms to 1s).
- The app writes the serialized scene to the active file path.
- If the write fails, the sidebar shows an error state on the active row (see NFR-6).
- Acceptance: Drawing a shape and waiting 1s leaves a file on disk that contains the shape.

#### FR-F5: Save As
- The user invokes Save As from a menu item. A keyboard shortcut is optional.
- The app opens a native save dialog. On confirm, it writes the scene to the new path, updates `FileRecord.path` for the active file, and updates the sidebar.
- If the old path was a draft, the draft file may remain. The MVP does not delete it.
- Acceptance: Save As to a new location moves the active file's history entry to the new path. Later auto-saves write to the new path.

#### FR-F6: History grouping
- The sidebar groups rows by the calendar day of `opened_at`, newest first.
- Date headers read `Today`, `Yesterday`, then `MMM D, YYYY` (for example `Nov 3, 2026`).
- Acceptance: Files opened today appear under "Today", files opened yesterday under "Yesterday", and older files under dated headers, newest first.

### 3.2 Sidebar

#### FR-S1: Layout
- A vertical column with the New button, the Open button, and a scrollable history list.
- The active file row has a distinct highlight.
- Acceptance: The sidebar renders all three regions, and the active row is visibly different from inactive rows.

#### FR-S2: Empty state
- When history is empty, the sidebar shows a muted "No files yet" message and the New and Open buttons.
- Acceptance: A fresh install shows the empty state, not a blank white panel.

### 3.3 Canvas and webview

#### FR-C1: Excalidraw embed
- A React page renders `<Excalidraw>` at `100vw × 100vh` within the canvas region.
- The page captures `excalidrawAPI` on mount and stores it for bridge use.
- The page registers an `onChange` handler that forwards debounced scene changes to Zig.
- Acceptance: All Excalidraw tools work, and drawing a shape triggers an auto-save.

#### FR-C2: File loading
- On `canvas.loadScene { path }`, the webview fetches the file, extracts the elements, and calls `updateScene`.
- If the file is missing or malformed, the webview returns `{ error }` to Zig, and Zig shows an error state.
- Acceptance: Loading a valid file renders it. Loading a corrupt file reports an error and does not crash.

#### FR-C3: Screenshot
- On `canvas.screenshot`, the webview renders the current scene to SVG and returns the SVG string. PNG is optional and deferred to V1.
- Acceptance: The MCP `screenshot` call returns a non-empty SVG that visually matches the canvas.

### 3.4 MCP server

#### FR-M1: Transport
- The MCP server exposes tools over stdio to AI agents.
- The server talks to the NanoUI app over a local WebSocket on a fixed port (default `7411`, configurable through an environment variable).
- The Zig shell hosts the WebSocket endpoint, and the MCP sidecar is the client.

#### FR-M2: `add_elements`
- Input: `{ elements: Element[] }` (Excalidraw element JSON).
- Behavior: append the elements to the current scene via `canvas.applyPatch { create: [...] }`.
- Output: `{ ok: true, added: N }`.
- Acceptance: Calling `add_elements` with one rectangle adds exactly that rectangle to the visible canvas.

#### FR-M3: `apply_scene`
- Input: `{ create?: Element[], update?: Element[], delete?: string[] }`.
- Behavior: a single `updateScene` call with the resulting element set.
- Output: `{ ok: true }`.
- Acceptance: A patch mixing create, update, and delete produces the expected final scene.

#### FR-M4: `get_scene`
- Output: `{ elements: Element[], appState: {...} }` from `getSceneElements()`.
- Acceptance: The returned elements match what is visible on the canvas.

#### FR-M5: `screenshot`
- Output: `{ svg: string }`.
- Acceptance: The SVG is a faithful render of the current scene.

#### FR-M6: `save_scene`
- Behavior: flush the current scene to the active file path, the same flush that auto-save uses.
- Output: `{ ok: true, path: string }`.
- Acceptance: After `save_scene`, the disk content matches the canvas content.

#### FR-M7: Error contract
- Every tool returns `{ ok: false, error: string }` on failure. No tool throws a raw exception to the AI client.
- Acceptance: Calling a tool with malformed input returns `{ ok: false, error }` and the sidecar keeps running.

### 3.5 Window

#### FR-W1: Split layout
- A single window with a fixed 240px sidebar and a canvas that takes the remaining width.
- Acceptance: Resizing the window keeps the sidebar width, and the canvas reflows.

#### FR-W2: Title
- The window title is the active file's basename, or `Untitled` if there is none.
- Acceptance: Opening a file updates the window title.

---

## 4. Non-functional requirements

| ID | Requirement | Target |
|---|---|---|
| NFR-1 | Cold start to interactive | < 2s |
| NFR-2 | Auto-save debounce | 500ms to 1s |
| NFR-3 | Bridge message size limit | Stay under NanoUI's 16 KiB cap. Use patches for large scenes. |
| NFR-4 | SQLite writes | Batched or transactional. Never block the UI thread. |
| NFR-5 | MCP tool latency | `add_elements` < 150ms end to end (excluding screenshot) |
| NFR-6 | Error surfacing | Every failure is visible in the UI. No silent data loss. |
| NFR-7 | Crash recovery | A malformed file load does not crash the app. It shows an error and keeps the prior scene. |
| NFR-8 | Logging | Structured logs in `<app-data>/logs/`. Log level set by the `LOG_LEVEL` environment variable. |
| NFR-9 | Binary size | Single Zig binary < 30 MB (webview assets bundled) |

---

## 5. Technical constraints

- Target platform: macOS only (WKWebView). Windows and Linux are deferred.
- Zig version: latest stable. Scaffold with `nui start excalidraw-client`.
- Bridge: use NanoUI's generated typed bridge (JS client and TS declarations generated from Zig types). Do not hand-write JSON marshalling.
- Webview assets: bundled into the Zig binary as static files and served from a local loopback origin.
- No cloud and no network egress, except the local WebSocket to the MCP sidecar.
- SQLite: one database at `<app-data>/history.db`. Migrations use a simple versioned schema table.
- State ownership: Zig owns `active_file_path`. React never decides which file is open.

---

## 6. Data model

### 6.1 SQLite schema

```sql
CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL);

CREATE TABLE IF NOT EXISTS files (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  path          TEXT NOT NULL UNIQUE,
  opened_at     INTEGER NOT NULL,   -- unix seconds
  element_count INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_files_opened_at ON files(opened_at DESC);
```

### 6.2 Zig types

```zig
pub const FileRecord = struct {
    id: u64,
    path: []const u8,
    opened_at: i64,
    element_count: u32,
};

pub const ActiveFile = struct {
    path: ?[]const u8,
    is_draft: bool,
    last_saved_at: i64,
    last_modified_at: i64,
};
```

### 6.3 Filesystem layout

```
<app-data>/
├── history.db
├── drafts/
│   └── Untitled-1.excalidraw
└── logs/
    └── app.log
```

---

## 7. Interface contracts

### 7.1 Bridge messages (Zig and webview)

All messages are JSON with a `type` field. Responses include `request_id`.

Zig to webview:

| type | payload | response |
|---|---|---|
| `canvas.loadScene` | `{ request_id, path }` | `{ request_id, ok, error? }` |
| `canvas.applyPatch` | `{ request_id, create?, update?, delete? }` | `{ request_id, ok, error? }` |
| `canvas.getScene` | `{ request_id }` | `{ request_id, ok, elements, appState }` |
| `canvas.screenshot` | `{ request_id }` | `{ request_id, ok, svg }` |

Webview to Zig:

| type | payload | notes |
|---|---|---|
| `scene.changed` | `{ elements, appState }` | Debounced 500ms to 1s. Used for auto-save. |
| `scene.loaded` | `{ path, element_count }` | Sent after a successful `loadScene`. |
| `scene.error` | `{ request_id, message }` | Sent on any failure. |

### 7.2 MCP tool signatures

```jsonc
// add_elements
// request
{ "elements": [ /* Excalidraw element JSON */ ] }
// response
{ "ok": true, "added": 1 }

// apply_scene
// request
{ "create": [...], "update": [...], "delete": ["id1", "id2"] }
// response
{ "ok": true }

// get_scene
// request
{}
// response
{ "elements": [...], "appState": {...} }

// screenshot
// request
{}
// response
{ "svg": "<svg ...>" }

// save_scene
// request
{}
// response
{ "ok": true, "path": "/Users/.../file.excalidraw" }
```

### 7.3 Local WebSocket protocol (MCP sidecar and Zig)

- Port: `7411` (set with the environment variable `EXCALIDRAW_WS_PORT`)
- Direction: the sidecar is the client, and Zig is the server.
- Message envelope: `{ "id": "<uuid>", "method": "<bridge type>", "params": {...} }`
- Response envelope: `{ "id": "<uuid>", "result": {...} }` or `{ "id": "<uuid>", "error": "..." }`
- Heartbeat: Zig pings every 5s. The sidecar exits if no pong arrives within 15s, which prevents orphaned processes.

---

## 8. Build order and milestones

Execute in this order. Each milestone must pass its acceptance checks before the next one starts.

### M1: Scaffold (0.5 day)
- Run `nui start excalidraw-client`.
- Commit the generated `build.zig`, view, and `AGENTS.md`.
- Verify that `nui dev` runs a blank window.
- Gate: The window opens with a native hello-world sidebar.

### M2: Native sidebar with SQLite (1 day)
- Implement the `files` table with insert, read, and list.
- Render the sidebar: buttons, empty state, grouped list.
- Hard-code 3 fake rows to verify grouping.
- Gate: `nui snapshot` shows grouped headers, and the empty state renders correctly.

### M3: Webview and Excalidraw embed (1 day)
- Add a minimal React app: `<Excalidraw excalidrawAPI={...} onChange={...} />`.
- Bundle it into the Zig binary and serve it locally.
- Wire the generated bridge: `canvas.loadScene`, `canvas.getScene`.
- Gate: The canvas renders Excalidraw, and `excalidrawAPI.getSceneElements()` works from the devtools console.

### M4: File lifecycle (1 day)
- Implement New File, Open From History, Open From Disk, Auto-save, and Save As.
- The sidebar shows the active file, and grouping updates on open.
- Gate: The full loop works. New, draw, wait 1s, file on disk, reopen, same scene.

### M5: MCP sidecar (1 day)
- Write the sidecar in Python or TS with a WebSocket client to Zig and an MCP stdio server.
- Implement `add_elements`, `apply_scene`, `get_scene`, `screenshot`, `save_scene`.
- Gate: From an MCP client, `add_elements` followed by `screenshot` returns an SVG containing the new shape.

### M6: End-to-end verification (0.5 day)
- Run the full loop: open the app, an AI adds a shape via MCP, take a screenshot, save, and confirm the sidebar shows the file.
- Integrate BrowserHarness so a coding agent can screenshot the full window.
- Gate: An agent completes the loop unassisted.

---

## 9. Definition of done (MVP)

The MVP is done when all of the following are true:

1. `nui build` produces a single macOS binary that launches with a native sidebar and an Excalidraw canvas.
2. A user can click "New file", draw, wait 1s, close the app, reopen it, and see the same scene via the sidebar.
3. A user can click "Open file" and load any `.excalidraw` file from disk.
4. An AI agent connected through MCP can:
   - Add a rectangle with `add_elements`
   - Read the scene with `get_scene`
   - Take a `screenshot` and see the rectangle
   - Persist with `save_scene`
   - See the file appear in history after the save
5. All 5 MCP tools pass their FR acceptance criteria in §3.4.
6. `LOG_LEVEL=debug` produces structured logs, and a malformed file load shows an error without crashing.
7. No out-of-scope features (§2.2) have been added.

---

## 10. Testing requirements

Unit tests (Zig):
- SQLite CRUD for `files`
- Day-grouping logic (`group_by_day`)
- Draft path generation (`Untitled-N` increases monotonically)
- Bridge message serialization round trip

Integration tests:
- Bridge: `loadScene`, then the `scene.loaded` event, then the SQLite write
- MCP: a mock WebSocket server asserts the correct bridge messages for each tool

Manual and agent tests:
- Full M4 and M6 loops through BrowserHarness
- Corrupt file load: edit an `.excalidraw` file to invalid JSON, then assert the error UI and no crash
- Kill the MCP sidecar mid-operation, then assert that Zig recovers

---

## 11. Risks and mitigations

| Risk | Mitigation |
|---|---|
| The NanoUI webview bridge has undocumented limits. | Prototype the bridge in M3 before committing to message shapes. Keep patches small. |
| Bundling React into the Zig binary is not obvious. | Serve from loopback HTTP through Zig's static asset handler. Do not try to inline it into the webview. |
| The MCP sidecar is orphaned on a crash. | Use the heartbeat (§7.3). Zig kills the child on exit. |
| Excalidraw version drift breaks the bridge. | Pin `@excalidraw/excalidraw` and record the exact version in `package.json` and the lockfile. |
| `updateScene` replaces the scene instead of patching it. | Build the final element array in the webview before calling it. Pass the full array from `apply_scene`. |
| macOS WKWebView devtools are unavailable in release builds. | Enable devtools in debug builds only, and document how to open them. |

---

## 12. Agent operating rules

Drop this section into `AGENTS.md` at the repo root.

```markdown
# AGENTS.md: Excalidraw Zig client (MVP)

## Project
Native NanoUI shell (Zig), embedded Excalidraw webview, and an MCP sidecar.
Read SRS.md for the full spec. This file summarizes the rules for autonomous coding.

## Golden rules
1. MVP scope only. See SRS §2.1. Do NOT add features from §2.2.
2. Do NOT reimplement Excalidraw drawing in Zig. Always use the webview.
3. The Zig shell owns `active_file_path`. React does not track which file is open.
4. Auto-save is the default. Manual save flushes.
5. All bridge messages are JSON with `request_id`. Use NanoUI's generated bridge. Do not hand-roll it.
6. All MCP tool failures return `{ ok: false, error }`. Never throw to the AI client.
7. Respect the NanoUI 16 KiB bridge limit. Send patches, not full scenes.

## Commands
- Scaffold:    `nui start excalidraw-client`
- Dev:         `nui dev`
- Build:       `nui build`
- Test:        `zig build test`
- Snapshot:    `nui snapshot` (native UI only)
- Web build:   `cd web && npm ci && npm run build`
- MCP:         `python -m mcp_server` or `node mcp/dist/index.js`

## Directory layout
- `src/`            Zig app: sidebar, bridge, SQLite, window
- `web/`            React and Excalidraw, bundled into the Zig binary
- `mcp/`            MCP sidecar (Python or TS)
- `assets/`         Icons and static files served by Zig
- `SRS.md`          The spec
- `AGENTS.md`       This file

## Build order
Follow SRS §8. Do not skip milestones. Do not build M5 before M4 works.

## Acceptance gates
Before claiming a milestone is done, run the exact acceptance check from SRS §8 for that milestone.

## When in doubt
- If scope is ambiguous, assume it is out of scope.
- If architecture is ambiguous, consult SRS §1.1.
- If bridge behavior is unclear, prototype it. Do not guess.
```
