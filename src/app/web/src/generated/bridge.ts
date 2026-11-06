// Adapts NanoUI's generated client (window.nanoui, flat CanvasWire since tsgen rejects unions) to the
// CanvasRequest shape canvas.ts uses. Regenerate the raw client: nanodraw --nanoui-generate=<dir>.
export type CanvasOp = { load: number } | { flush: number } | { apply: {} } | { get_scene: {} } | { screenshot: {} };
export interface CanvasRequest { request_id: number; op: CanvasOp }
export interface CanvasReply { request_id: number; err: string | null }
export interface Row { path: string; label: string; active: boolean; err?: string | null; count: number; opened_at: number }
export interface Section { header: string; rows: Row[] }
export interface ViewModel { title: string; enabled: boolean; banner?: string | null; sections: Section[] }
export interface Bridge {
  onViewModel(cb: (v: ViewModel) => void): void;
  setTitle(title: string): void;
  newFile(): void;
  openFile(): void;
  openPath(path: string): void;
  onCanvasRequest(cb: (r: CanvasRequest) => void): void;
  canvasReply(r: CanvasReply): void;
  canvasReady(): void;
  saveAsRequested(): void;
}

interface CanvasWire { request_id: number; op: "load" | "flush" | "apply" | "get_scene" | "screenshot"; doc?: number | null }
interface Nanoui { window: { setTitle(t: string): void }; log(...v: unknown[]): void; call(m: string, ...a: unknown[]): Promise<unknown>; on(e: string, f: (p: unknown) => void): () => void }

const nanoui = (globalThis as { nanoui?: Nanoui }).nanoui;
// Page errors go to Zig's stderr (no console without the inspector).
if (nanoui) {
  addEventListener("error", (e) => nanoui.log("page error:", e.message));
  addEventListener("unhandledrejection", (e) => nanoui.log("page rejection:", String(e.reason)));
}
const fire = (m: string, ...a: unknown[]) => { nanoui?.call(`Bridge.${m}`, ...a).catch((e) => nanoui.log(`bridge.${m} failed:`, String(e))); };

const unwire = ({ request_id, op, doc }: CanvasWire): CanvasRequest => ({
  request_id,
  op: op === "load" || op === "flush" ? ({ [op]: doc as number } as CanvasOp) : ({ [op]: {} } as CanvasOp),
});

// Without the runtime (vite build, unit tests) calls are no-ops.
export const bridge: Bridge = {
  onCanvasRequest: (cb) => { nanoui?.on("canvasRequest", (p) => cb(unwire(p as CanvasWire))); },
  canvasReply: (r) => fire("canvasReply", r),
  canvasReady: () => fire("canvasReady"),
  saveAsRequested: () => fire("saveAsRequested"),
  onViewModel: (cb) => { nanoui?.on("viewModel", (p) => cb(p as ViewModel)); },
  setTitle: (t) => nanoui?.window.setTitle(t),
  newFile: () => fire("newFile"),
  openFile: () => fire("openFile"),
  openPath: (p) => fire("openPath", p),
};
