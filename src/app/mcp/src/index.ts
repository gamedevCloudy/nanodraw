import { pathToFileURL } from "node:url";
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";
import { createLink, type Link } from "./link.js";

const Element = z.looseObject({ type: z.string(), id: z.string().optional() });
const Update = z.looseObject({ id: z.string() });
const Empty = z.object({});
const schemas = {
  add_elements: z.object({ elements: z.array(Element).min(1) }),
  apply_scene: z.object({
    create: z.array(Element).optional(),
    update: z.array(Update).optional(),
    delete: z.array(z.string()).optional(),
  }),
  get_scene: Empty,
  screenshot: Empty,
  save_scene: Empty,
};
type Name = keyof typeof schemas;

const arr = { type: "array", items: { type: "object" } };
const none = { type: "object", properties: {} };
const tools = [
  { name: "add_elements", description: "Add Excalidraw elements to the canvas (element skeletons).", inputSchema: { type: "object", properties: { elements: { ...arr, minItems: 1 } }, required: ["elements"] } },
  { name: "apply_scene", description: "Atomically create/update/delete elements by id.", inputSchema: { type: "object", properties: { create: arr, update: arr, delete: { type: "array", items: { type: "string" } } } } },
  { name: "get_scene", description: "Return the current elements and appState.", inputSchema: none },
  { name: "screenshot", description: "Return the canvas as SVG.", inputSchema: none },
  { name: "save_scene", description: "Save the active file; returns its path.", inputSchema: none },
];

async function run(link: Link, name: Name, a: any) {
  switch (name) {
    case "add_elements":
      await link.call("canvas.applyPatch", { create: a.elements });
      return { added: a.elements.length };
    case "apply_scene": {
      const r = await link.call("canvas.applyPatch", a);
      return r?.warnings ? { warnings: r.warnings } : {};
    }
    case "get_scene": {
      const f = await link.call("canvas.getScene", {});
      return { elements: f.elements, appState: f.appState };
    }
    case "screenshot":
      return { svg: (await link.call("canvas.screenshot", {})).svg };
    case "save_scene":
      return { path: (await link.call("file.save", {})).path };
  }
}

export function makeServer(link: Link) {
  const server = new Server({ name: "excalidraw", version: "0.1.0" }, { capabilities: { tools: {} } });
  server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools }));
  // Low-level handler so our safeParse owns validation: errors are {ok:false,error}, never JSON-RPC errors.
  server.setRequestHandler(CallToolRequestSchema, async (req) => {
    const reply = (body: object, isError = false) => ({ content: [{ type: "text" as const, text: JSON.stringify(body) }], isError });
    try {
      const name = req.params.name as Name;
      if (!Object.hasOwn(schemas, name)) return reply({ ok: false, error: `unknown tool ${req.params.name}` }, true);
      const p = schemas[name].safeParse(req.params.arguments ?? {});
      if (!p.success) return reply({ ok: false, error: z.prettifyError(p.error) }, true);
      return reply({ ok: true, ...(await run(link, name, p.data)) });
    } catch (e) {
      return reply({ ok: false, error: e instanceof Error ? e.message : String(e) }, true);
    }
  });
  return server;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const link = createLink();
  process.stdin.on("end", () => process.exit(0)); // process lifetime = stdin
  await makeServer(link).connect(new StdioServerTransport());
}
