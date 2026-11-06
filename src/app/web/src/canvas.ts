import { CaptureUpdateAction, exportToSvg, restore, serializeAsJSON } from "@excalidraw/excalidraw";
import type { ExcalidrawImperativeAPI } from "@excalidraw/excalidraw/types";
import { bridge, type CanvasRequest } from "./generated/bridge";
import { resolvePatch } from "./patch";
import { getTheme } from "./theme";

type Snapshot = { readonly doc: number; readonly bytes: string; readonly count: number; readonly dirty: boolean };

const SAVE_DEBOUNCE_MS = 700;
const RETRY_MS = 5000;

let api: ExcalidrawImperativeAPI | null = null;
let doc: number | null = null; // the DocId the canvas is showing
let lastSaved = ""; // bytes last accepted by Zig for `doc`
let chain: Promise<void> = Promise.resolve();
let queue: Promise<void> = Promise.resolve();
let debounce: ReturnType<typeof setTimeout> | undefined;
let retry: ReturnType<typeof setTimeout> | undefined;

// Zig puts the token in the page URL hash; accept "#<token>" or "#token=<token>".
const token = () => location.hash.slice(1).replace(/^token=/, "");
const call = (path: string, init: RequestInit = {}) =>
  fetch(path, {
    ...init,
    headers: { ...init.headers, "X-Nanodraw": "1", Authorization: `Bearer ${token()}` },
  });

// Autosave indicator for the sidebar; Cmd+S goes through putDoc too.
export type Status = { s: "idle" | "saving" | "failed" } | { s: "saved"; at: number };
let status: Status = { s: "idle" };
const subs = new Set<() => void>();
const setStatus = (s: Status) => { status = s; subs.forEach((f) => f()); };
export const getStatus = () => status;
// Count of agent-applied changes, for the sidebar's "Agent edited" pulse.
let agentEdits = 0;
export const getAgentEdits = () => agentEdits;
export const subscribe = (f: () => void) => (subs.add(f), () => { subs.delete(f); });

export const uiOptions = { canvasActions: { loadScene: false, saveToActiveFile: false } };

export function attach(a: ExcalidrawImperativeAPI): void {
  api = a;
  bridge.canvasReady();
}

export function onChange(): void {
  clearTimeout(debounce);
  debounce = setTimeout(() => {
    const s = takeSnapshot();
    if (s?.dirty) putDoc(s).catch(() => {}); // failure already armed the retry
  }, SAVE_DEBOUNCE_MS);
}

export function enqueue(req: CanvasRequest): void {
  queue = queue.then(() => run(req));
}

// The ONLY snapshot constructor: doc id and scene are read in one synchronous step.
function takeSnapshot(): Snapshot | null {
  if (!api || doc === null) return null;
  const elements = api.getSceneElements();
  const bytes = serializeAsJSON(elements, api.getAppState(), api.getFiles(), "local");
  return { doc, bytes, count: elements.length, dirty: bytes !== lastSaved };
}

// The ONLY writer: one PUT in flight, in snapshot order.
function putDoc(s: Snapshot, force = false): Promise<void> {
  if (!force && !s.dirty) return Promise.resolve();
  chain = chain.catch(() => {}).then(async () => {
    setStatus({ s: "saving" });
    try {
      const r = await call(`/doc/${s.doc}`, { method: "PUT", body: s.bytes, headers: { "X-Element-Count": String(s.count) } });
      if (!r.ok) throw new Error(`save failed: ${r.status} ${await r.text()}`);
      if (doc === s.doc) lastSaved = s.bytes;
      setStatus({ s: "saved", at: Date.now() });
    } catch (e) {
      setStatus({ s: "failed" });
      clearTimeout(retry);
      retry = setTimeout(() => { const n = takeSnapshot(); if (n) putDoc(n).catch(() => {}); }, RETRY_MS);
      throw e;
    }
  });
  return chain;
}

const flushNow = () => { const s = takeSnapshot(); return s ? putDoc(s, true) : Promise.resolve(); };

addEventListener("keydown", (e) => {
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "s") {
    e.preventDefault();
    flushNow().catch(() => {});
  }
});

const getRpc = async (rid: number) => {
  const r = await call(`/rpc/${rid}`);
  if (!r.ok) throw new Error(`rpc ${rid}: ${r.status}`);
  return r.text();
};
const putRpc = async (rid: number, body: string) => {
  const r = await call(`/rpc/${rid}`, { method: "PUT", body });
  if (!r.ok) throw new Error(`rpc ${rid}: ${r.status}`);
};

async function load(id: number) {
  if (!api) throw new Error("canvas not attached");
  const r = await call(`/doc/${id}`);
  if (!r.ok) throw new Error(`load ${id}: ${r.status}`);
  const text = await r.text();
  const data = restore(text.trim() ? JSON.parse(text) : null, null, null);
  const s = takeSnapshot(); // flush the previous doc before the swap; a failure aborts the load
  if (s?.dirty) await putDoc(s);
  api.updateScene({ elements: data.elements, appState: { ...data.appState, theme: getTheme() }, // files carry their own theme; the app theme wins
    captureUpdate: CaptureUpdateAction.NEVER });
  api.addFiles(Object.values(data.files ?? {}));
  api.history.clear();
  doc = id;
  clearTimeout(debounce);
  await new Promise((res) => setTimeout(res, 0)); // let React apply appState before we record the baseline
  lastSaved = takeSnapshot()!.bytes;
}

async function run({ request_id: rid, op }: CanvasRequest) {
  let err: string | null = null;
  try {
    if (!api) throw new Error("canvas not attached");
    if ("load" in op) await load(op.load);
    else if ("flush" in op) {
      if (doc !== op.flush) throw new Error(`canvas is not showing doc ${op.flush}`);
      await flushNow();
    } else if ("apply" in op) {
      const patch = JSON.parse(await getRpc(rid)); // the only await; the read-modify-write below is one sync task
      const { elements, warnings } = resolvePatch(api.getSceneElementsIncludingDeleted(), patch);
      api.updateScene({ elements, captureUpdate: CaptureUpdateAction.IMMEDIATELY });
      if (warnings.length) console.warn("apply warnings", warnings);
      agentEdits++; subs.forEach((f) => f());
    } else if ("get_scene" in op) {
      await putRpc(rid, serializeAsJSON(api.getSceneElements(), api.getAppState(), api.getFiles(), "local"));
    } else if ("screenshot" in op) {
      const svg = await exportToSvg({ elements: api.getSceneElements(), appState: api.getAppState(), files: api.getFiles() });
      await putRpc(rid, JSON.stringify({ svg: svg.outerHTML }));
    }
  } catch (e) {
    err = (e instanceof Error ? e.message : String(e)).slice(0, 1024);
  }
  bridge.canvasReply({ request_id: rid, err });
}

bridge.onCanvasRequest(enqueue);
