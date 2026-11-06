import { afterEach, beforeEach, expect, test, vi } from "vitest";

const mem = () => { const m = new Map<string, string>(); return { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, v) }; };
const throwing = { getItem: () => { throw new Error("denied"); }, setItem: () => { throw new Error("denied"); } };
const load = async () => { vi.resetModules(); return import("./theme"); };

beforeEach(() => vi.stubGlobal("matchMedia", () => ({ matches: false })));
afterEach(() => vi.unstubAllGlobals());

test("theme: saved choice wins, invalid falls back to system", async () => {
  vi.stubGlobal("localStorage", mem()); localStorage.setItem("nanodraw.theme", "dark");
  expect((await load()).getTheme()).toBe("dark");
  localStorage.setItem("nanodraw.theme", "bogus");
  expect((await load()).getTheme()).toBe("light");
});

test("theme: toggle persists and survives reload", async () => {
  vi.stubGlobal("localStorage", mem());
  (await load()).toggleTheme();
  expect(localStorage.getItem("nanodraw.theme")).toBe("dark");
  expect((await load()).getTheme()).toBe("dark");
});

test("throwing storage: reads default, writes swallowed, toggle works in memory", async () => {
  vi.stubGlobal("localStorage", throwing);
  const t = await load();
  expect(t.getTheme()).toBe("light");
  t.toggleTheme();
  expect(t.getTheme()).toBe("dark");
  expect(t.readPref("nanodraw.sidebar")).toBeNull();
  expect(() => t.writePref("nanodraw.sidebar", "1")).not.toThrow();
});

test("sidebar-collapsed pref roundtrip", async () => {
  vi.stubGlobal("localStorage", mem());
  const t = await load();
  expect(t.readPref("nanodraw.sidebar")).toBeNull();
  t.writePref("nanodraw.sidebar", "1");
  expect(t.readPref("nanodraw.sidebar")).toBe("1");
});
