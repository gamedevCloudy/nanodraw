// Values copied from @excalidraw/excalidraw's index.css (:root / .excalidraw.theme--dark) so sidebar and canvas read as one surface. Light err and dark muted adjusted for WCAG 4.5:1 (contrast.test.ts).
export type Theme = "light" | "dark";
export const palette = {
  light: { bg: "#ffffff", border: "#f1f0ff", text: "#1b1b1f", muted: "#5c5c5c", row: "#e3e2fe", rowText: "#030064", btn: "#e9ecef", accent: "#6965db", accentText: "#ffffff", err: "#ba5956" },
  dark: { bg: "#232329", border: "#31303b", text: "#e3e3e8", muted: "#c3c3c3", row: "#4f4d6f", rowText: "#e0dfff", btn: "#363636", accent: "#a8a5ff", accentText: "#121212", err: "#ffa8a5" },
};
export const canvasBg = { light: "#ffffff", dark: "#121212" };

// Storage can throw (disabled, sandboxed); a lost preference must never break the UI.
export const readPref = (k: string): string | null => { try { return localStorage.getItem(k); } catch { return null; } };
export const writePref = (k: string, v: string): void => { try { localStorage.setItem(k, v); } catch { /* not persisted */ } };

const KEY = "excalibre.theme";
const system = (): Theme => (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
const saved = readPref(KEY);
let theme: Theme = saved === "light" || saved === "dark" ? saved : system();
const subs = new Set<() => void>();
export const getTheme = () => theme;
export const subscribeTheme = (f: () => void) => (subs.add(f), () => { subs.delete(f); });
export function toggleTheme(): void {
  theme = theme === "dark" ? "light" : "dark";
  writePref(KEY, theme);
  subs.forEach((f) => f());
}
