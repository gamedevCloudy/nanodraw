import { afterEach, beforeEach, expect, test, vi } from "vitest";

const mem = () => { const m = new Map<string, string>(); return { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, v) }; };
const throwing = { getItem: () => { throw new Error("denied"); }, setItem: () => { throw new Error("denied"); } };
const load = async () => { vi.resetModules(); return import("./theme"); };

beforeEach(() => vi.stubGlobal("matchMedia", () => ({ matches: false })));
afterEach(() => vi.unstubAllGlobals());

test("theme: saved choice wins, invalid falls back to system", async () => {
  vi.stubGlobal("localStorage", mem()); localStorage.setItem("excalibre.theme", "dark");
  expect((await load()).getTheme()).toBe("dark");
  localStorage.setItem("excalibre.theme", "bogus");
  expect((await load()).getTheme()).toBe("light");
});

test("theme: toggle persists and survives reload", async () => {
  vi.stubGlobal("localStorage", mem());
  (await load()).toggleTheme();
  expect(localStorage.getItem("excalibre.theme")).toBe("dark");
  expect((await load()).getTheme()).toBe("dark");
});

test("throwing storage: reads default, writes swallowed, toggle works in memory", async () => {
  vi.stubGlobal("localStorage", throwing);
  const t = await load();
  expect(t.getTheme()).toBe("light");
  t.toggleTheme();
  expect(t.getTheme()).toBe("dark");
  expect(t.readPref("excalibre.sidebar")).toBeNull();
  expect(() => t.writePref("excalibre.sidebar", "1")).not.toThrow();
});

test("sidebar-collapsed pref roundtrip", async () => {
  vi.stubGlobal("localStorage", mem());
  const t = await load();
  expect(t.readPref("excalibre.sidebar")).toBeNull();
  t.writePref("excalibre.sidebar", "1");
  expect(t.readPref("excalibre.sidebar")).toBe("1");
});
