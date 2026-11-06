import { expect, test, vi } from "vitest";

vi.stubGlobal("matchMedia", () => ({ matches: false })); // theme.ts reads it at module load
const { palette } = await import("./theme");

const lum = (h: string) => {
  const c = [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16) / 255).map((v) => (v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4));
  return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
};
const ratio = (a: string, b: string) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };

// [foreground, background] pairs actually rendered by Sidebar.
const pairs: [string, string][] = [["text", "bg"], ["muted", "bg"], ["err", "bg"], ["rowText", "row"], ["muted", "row"], ["text", "btn"], ["accentText", "accent"], ["accent", "bg"]];
for (const th of ["light", "dark"] as const)
  for (const [f, b] of pairs)
    test(`${th} ${f} on ${b} >= 4.5`, () => {
      const P = palette[th] as Record<string, string>;
      const r = ratio(P[f], P[b]);
      console.log(`RATIO ${th} ${f} on ${b} ${r.toFixed(2)}`);
      expect(r).toBeGreaterThanOrEqual(4.5);
    });
