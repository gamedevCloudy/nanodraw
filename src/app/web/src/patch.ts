import { convertToExcalidrawElements } from "@excalidraw/excalidraw";
import type { ExcalidrawElement } from "@excalidraw/excalidraw/element/types";

export type Patch = {
  create?: Parameters<typeof convertToExcalidrawElements>[0];
  update?: ({ id: string } & Partial<ExcalidrawElement>)[];
  delete?: string[];
};
export class PatchError extends Error {}

const bump = <T extends ExcalidrawElement>(e: T, prev?: ExcalidrawElement): T => ({
  ...e,
  version: (prev?.version ?? e.version ?? 0) + 1,
  versionNonce: Math.floor(Math.random() * 2 ** 31),
  updated: Date.now(),
});

export function resolvePatch(
  cur: readonly ExcalidrawElement[],
  p: Patch,
): { elements: ExcalidrawElement[]; warnings: string[] } {
  const warnings: string[] = [];
  const seen = new Set<string>();
  const claim = (id: string) => {
    if (seen.has(id)) throw new PatchError(`id ${id} appears more than once in the patch`);
    seen.add(id);
  };
  for (const id of p.delete ?? []) claim(id);
  for (const u of p.update ?? []) claim(u.id);
  const created = convertToExcalidrawElements(p.create ?? [], { regenerateIds: false }) as ExcalidrawElement[];
  for (const c of created) claim(c.id);

  const m = new Map(cur.map((e) => [e.id, e]));
  for (const u of p.update ?? []) {
    const e = m.get(u.id);
    if (!e || e.isDeleted) throw new PatchError(`update: no element ${u.id}`);
  }
  for (const id of p.delete ?? []) {
    const e = m.get(id);
    if (!e || e.isDeleted) warnings.push(`delete: no element ${id}`);
    else m.set(id, bump({ ...e, isDeleted: true }, e));
  }
  for (const u of p.update ?? []) {
    const e = m.get(u.id)!;
    m.set(u.id, bump({ ...e, ...u, id: e.id, type: e.type } as ExcalidrawElement, e)); // type is immutable
  }
  for (const c of created) {
    const prev = m.get(c.id);
    if (prev) warnings.push(`create: id ${c.id} already existed, overwritten`);
    m.set(c.id, bump(c, prev));
  }
  return { elements: [...m.values()], warnings };
}
