import { readFileSync } from "node:fs";
import { afterEach, describe, expect, it } from "vitest";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { WebSocketServer, WebSocket } from "ws";
import { makeServer } from "../src/index.js";
import { createLink } from "../src/link.js";

const fixture = readFileSync(new URL("./ws-calls.jsonl", import.meta.url), "utf8").trim().split("\n").map((l) => JSON.parse(l));
const byMethod = (m: string) => fixture.find((f) => f.method === m);
const results: Record<string, unknown> = {
  "canvas.applyPatch": {}, "canvas.getScene": { elements: [{ id: "a" }], appState: { zoom: 1 } },
  "canvas.screenshot": { svg: "<svg/>" }, "file.save": { path: "/tmp/x.excalidraw" },
};

let wss: WebSocketServer; let seen: any[]; let sockets: WebSocket[]; let origins: (string | undefined)[];
let cleanup: (() => void)[] = [];
afterEach(() => { cleanup.forEach((f) => f()); cleanup = []; wss?.close(); });

async function setup(opts: { silent?: boolean; callTimeoutMs?: number; pingTimeoutMs?: number } = {}) {
  seen = []; sockets = []; origins = [];
  wss = new WebSocketServer({ port: 0, path: "/mcp" } as any);
  await new Promise((r) => wss.on("listening", r));
  wss.on("connection", (s, req) => {
    sockets.push(s); origins.push(req.headers.origin);
    s.on("message", (d) => {
      const m = JSON.parse(d.toString()); seen.push(m);
      if (!opts.silent) s.send(JSON.stringify({ id: m.id, result: results[m.method] }));
    });
  });
  const link = createLink({ port: (wss.address() as any).port, ...opts });
  const [ct, st] = InMemoryTransport.createLinkedPair();
  await makeServer(link).connect(st);
  const client = new Client({ name: "t", version: "0" });
  await client.connect(ct);
  cleanup.push(() => { link.close(); client.close(); });
  const call = async (name: string, args: any = {}) => {
    const r: any = await client.callTool({ name, arguments: args });
    return { isError: r.isError, body: JSON.parse(r.content[0].text) };
  };
  return { call, client };
}
const frame = (i: number) => ({ method: seen[i].method, params: seen[i].params });
const want = (m: string) => ({ method: m, params: byMethod(m).params });

describe("tools emit the fixture lines", () => {
  it("lists exactly 5 tools", async () => {
    const { client } = await setup();
    expect((await client.listTools()).tools.map((t) => t.name).sort()).toEqual(["add_elements", "apply_scene", "get_scene", "save_scene", "screenshot"]);
  });
  it("add_elements", async () => {
    const { call } = await setup();
    const r = await call("add_elements", { elements: byMethod("canvas.applyPatch").params.create });
    expect(r).toEqual({ isError: false, body: { ok: true, added: 1 } });
    expect(frame(0)).toEqual(want("canvas.applyPatch"));
    expect(origins[0]).toBeUndefined();
  });
  it("apply_scene passes patch and warnings through", async () => {
    const { call } = await setup();
    results["canvas.applyPatch"] = { warnings: ["w"] };
    const r = await call("apply_scene", byMethod("canvas.applyPatch").params);
    results["canvas.applyPatch"] = {};
    expect(r.body).toEqual({ ok: true, warnings: ["w"] });
    expect(frame(0)).toEqual(want("canvas.applyPatch"));
  });
  it("get_scene / screenshot / save_scene", async () => {
    const { call } = await setup();
    expect((await call("get_scene")).body).toEqual({ ok: true, elements: [{ id: "a" }], appState: { zoom: 1 } });
    expect((await call("screenshot")).body).toEqual({ ok: true, svg: "<svg/>" });
    expect((await call("save_scene")).body).toEqual({ ok: true, path: "/tmp/x.excalidraw" });
    expect([0, 1, 2].map(frame)).toEqual(["canvas.getScene", "canvas.screenshot", "file.save"].map(want));
  });
});

describe("error contract", () => {
  it.each([
    ["add_elements", {}], ["add_elements", { elements: [] }], ["add_elements", { elements: [{ id: "x" }] }],
    ["apply_scene", { update: [{ type: "rectangle" }] }], ["apply_scene", { delete: [1] }], ["nope", {}],
  ])("%s %j -> ok:false isError, nothing sent", async (name, args) => {
    const { call } = await setup();
    const r = await call(name, args);
    expect(r.isError).toBe(true);
    expect(r.body.ok).toBe(false);
    expect(typeof r.body.error).toBe("string");
    expect(seen).toHaveLength(0);
  });
  it("app error becomes ok:false", async () => {
    const { call } = await setup();
    wss.removeAllListeners("connection");
    wss.on("connection", (s) => s.on("message", (d) => s.send(JSON.stringify({ id: JSON.parse(d.toString()).id, error: "canvas not ready" }))));
    expect(await call("get_scene")).toEqual({ isError: true, body: { ok: false, error: "canvas not ready" } });
  });
  it("fails fast when app is down", async () => {
    const link = createLink({ port: 1 });
    cleanup.push(() => link.close());
    await expect(link.call("canvas.getScene", {})).rejects.toThrow("app not connected");
    const t = Date.now();
    await expect(link.call("canvas.getScene", {})).rejects.toThrow("app not connected");
    expect(Date.now() - t).toBeLessThan(200);
  });
});

describe("timeout and disconnect", () => {
  it("times out with the documented message", async () => {
    const { call } = await setup({ silent: true, callTimeoutMs: 100 });
    const r = await call("get_scene");
    expect(r.body).toEqual({ ok: false, error: "timed out; the change may still apply, call get_scene" });
  });
  it("rejects pending with 'app disconnected' on close, then reconnects", async () => {
    const { call } = await setup({ silent: true });
    const p = call("get_scene");
    await new Promise((r) => setTimeout(r, 100));
    sockets[0].terminate();
    expect((await p).body).toEqual({ ok: false, error: "app disconnected" });
    await new Promise((r) => setTimeout(r, 800));
    expect(sockets.length).toBe(2);
  });
  it("ping watchdog terminates and rejects when pings stop", async () => {
    const { call } = await setup({ silent: true, pingTimeoutMs: 150 });
    const r = await call("get_scene");
    expect(r.body).toEqual({ ok: false, error: "app disconnected" });
  });
  it("pings keep the link alive and are answered with pong", async () => {
    const { call } = await setup({ pingTimeoutMs: 300 });
    await call("get_scene");
    let pongs = 0;
    sockets[0].on("pong", () => pongs++);
    for (let i = 0; i < 4; i++) { sockets[0].ping(); await new Promise((r) => setTimeout(r, 100)); }
    expect(pongs).toBe(4);
    expect((await call("get_scene")).body.ok).toBe(true); // 400ms > 300ms watchdog, still connected
    expect(sockets.length).toBe(1);
  });
});
