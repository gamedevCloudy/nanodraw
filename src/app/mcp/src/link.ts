import { randomUUID } from "node:crypto";
import WebSocket from "ws";

type Pending = { resolve: (v: any) => void; reject: (e: Error) => void; timer: NodeJS.Timeout };
export type Link = { call(method: string, params: unknown): Promise<any>; close(): void };

export function createLink(opts: { port?: number; callTimeoutMs?: number; pingTimeoutMs?: number } = {}): Link {
  const port = opts.port ?? Number(process.env.EXCALIDRAW_WS_PORT ?? 7411);
  const callTimeout = opts.callTimeoutMs ?? 15_000;
  const pingTimeout = opts.pingTimeoutMs ?? 15_000;
  const url = `ws://127.0.0.1:${port}/mcp`;
  const pending = new Map<string, Pending>();
  let ws: WebSocket | undefined;
  let open = false;
  let backoff = 500;
  let retry: NodeJS.Timeout | undefined;
  let watchdog: NodeJS.Timeout | undefined;
  let closed = false;
  let first: Promise<void> | undefined; // lazy first connect

  const rejectAll = (msg: string) => {
    for (const [id, p] of pending) { clearTimeout(p.timer); p.reject(new Error(msg)); pending.delete(id); }
  };
  const arm = () => {
    clearTimeout(watchdog);
    watchdog = setTimeout(() => ws?.terminate(), pingTimeout); // terminate -> 'close' -> rejectAll
  };

  function connect(): Promise<void> {
    return new Promise((resolve) => {
      const s = new WebSocket(url); // ws sends no Origin header by default
      ws = s;
      s.on("open", () => { open = true; backoff = 500; arm(); resolve(); });
      s.on("ping", arm); // ws auto-replies with pong
      s.on("message", (data) => {
        let m: any;
        try { m = JSON.parse(data.toString()); } catch { return; }
        const p = pending.get(m?.id);
        if (!p) return; // late reply after timeout
        pending.delete(m.id);
        clearTimeout(p.timer);
        if (m.error !== undefined) p.reject(new Error(String(m.error)));
        else p.resolve(m.result);
      });
      s.on("error", () => {}); // 'close' follows
      s.on("close", () => {
        if (ws !== s) return;
        open = false; clearTimeout(watchdog); rejectAll("app disconnected");
        resolve();
        if (closed) return;
        retry = setTimeout(connect, backoff);
        retry.unref();
        backoff = Math.min(backoff * 2, 5000);
      });
    });
  }

  return {
    async call(method, params) {
      if (!first) first = connect();
      if (!open) { await first; if (!open) throw new Error("app not connected"); }
      return new Promise((resolve, reject) => {
        const id = randomUUID();
        const timer = setTimeout(() => {
          pending.delete(id);
          reject(new Error("timed out; the change may still apply, call get_scene"));
        }, callTimeout);
        pending.set(id, { resolve, reject, timer });
        ws!.send(JSON.stringify({ id, method, params }));
      });
    },
    close() { closed = true; clearTimeout(retry); clearTimeout(watchdog); rejectAll("closed"); ws?.terminate(); },
  };
}
