import { describe, expect, it, vi } from "vitest";

// convertToExcalidrawElements needs the full lib (canvas/fonts); the real one is covered by the app. Stub it.
vi.mock("@excalidraw/excalidraw", () => ({
  convertToExcalidrawElements: (xs: any[]) => xs.map((x) => ({ version: 1, isDeleted: false, ...x })),
}));
import { PatchError, resolvePatch } from "./patch";

const el = (id: string, extra = {}) => ({ id, type: "rectangle", version: 3, isDeleted: false, x: 0, ...extra }) as any;

describe("resolvePatch", () => {
  it("mixes create, update, delete and keeps z-order", () => {
    const { elements, warnings } = resolvePatch([el("a"), el("b"), el("c")], {
      create: [{ id: "d", type: "ellipse" } as any],
      update: [{ id: "a", x: 5 }],
      delete: ["b"],
    });
    expect(elements.map((e) => e.id)).toEqual(["a", "b", "c", "d"]);
    expect(elements[0].x).toBe(5);
    expect(elements[1].isDeleted).toBe(true);
    expect(warnings).toEqual([]);
  });
  it("bumps version and nonce", () => {
    const { elements } = resolvePatch([el("a")], { update: [{ id: "a", x: 1 }] });
    expect(elements[0].version).toBe(4);
    expect(elements[0].versionNonce).toBeTypeOf("number");
  });
  it("rejects an id in two lists, atomically", () => {
    expect(() => resolvePatch([el("a")], { update: [{ id: "a" }], delete: ["a"] })).toThrow(PatchError);
  });
  it("update of missing or tombstoned element throws; type is immutable", () => {
    expect(() => resolvePatch([], { update: [{ id: "x" }] })).toThrow(PatchError);
    expect(() => resolvePatch([el("a", { isDeleted: true })], { update: [{ id: "a" }] })).toThrow(PatchError);
    expect(resolvePatch([el("a")], { update: [{ id: "a", type: "ellipse" } as any] }).elements[0].type).toBe("rectangle");
  });
  it("delete of unknown or already-deleted id warns", () => {
    const r = resolvePatch([el("a", { isDeleted: true })], { delete: ["a", "zz"] });
    expect(r.warnings).toHaveLength(2);
  });
  it("create upserts an existing id with a warning and bumped version", () => {
    const r = resolvePatch([el("a")], { create: [{ id: "a", type: "ellipse" } as any] });
    expect(r.elements).toHaveLength(1);
    expect(r.elements[0].type).toBe("ellipse");
    expect(r.elements[0].version).toBe(4);
    expect(r.warnings).toHaveLength(1);
  });
});
