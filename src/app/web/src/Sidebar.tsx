import { useEffect, useState, useSyncExternalStore } from "react";
import logo from "./assets/logo.svg";
import { getStatus, subscribe } from "./canvas";
import { getTheme, palette, subscribeTheme, toggleTheme } from "./theme";
import { bridge, type ViewModel } from "./generated/bridge";

const ago = (t: number) => {
  const s = Math.max(0, Date.now() / 1000 - t);
  return s < 60 ? "just now" : s < 3600 ? `${Math.floor(s / 60)}m ago` : s < 86400 ? `${Math.floor(s / 3600)}h ago` : `${Math.floor(s / 86400)}d ago`;
};

type P = (typeof palette)["light"];
const btn = (C: P, off: boolean): React.CSSProperties => ({
  flex: 1, padding: "6px 0", border: 0, borderRadius: 6, font: "inherit", cursor: off ? "default" : "pointer",
  background: C.btn, color: C.text, opacity: off ? 0.45 : 1,
});
const icon = (C: P): React.CSSProperties => ({ border: 0, background: "none", color: C.muted, cursor: "pointer", padding: 4, display: "flex" });
const svg = { width: 16, height: 16, viewBox: "0 0 16 16", fill: "none", stroke: "currentColor", strokeWidth: 1.5, strokeLinecap: "round", strokeLinejoin: "round" } as const;
const KEY = "excalibre.sidebar";
const wasCollapsed = () => { try { return localStorage.getItem(KEY) === "1"; } catch { return false; } };

export function Sidebar() {
  const [vm, setVm] = useState<ViewModel | null>(null);
  const [dismissed, setDismissed] = useState<string | null>(null);
  useEffect(() => bridge.onViewModel((v) => { setVm(v); bridge.setTitle(v.title); }), []);
  const st = useSyncExternalStore(subscribe, getStatus);
  const [, tick] = useState(0);
  useEffect(() => { const t = setInterval(() => tick((n) => n + 1), 30000); return () => clearInterval(t); }, []);
  const theme = useSyncExternalStore(subscribeTheme, getTheme);
  const C = palette[theme];
  const [collapsed, setCollapsed] = useState(wasCollapsed);
  const collapse = () => { setCollapsed(!collapsed); try { localStorage.setItem(KEY, collapsed ? "0" : "1"); } catch { /* not persisted */ } };
  const off = !vm?.enabled;
  const banner = vm?.banner && vm.banner !== dismissed ? vm.banner : null;
  return (
    <aside onTransitionEnd={() => dispatchEvent(new Event("resize"))} // Excalidraw re-measures on window resize
      style={{ width: collapsed ? 44 : 240, transition: "width 160ms", overflow: "hidden", flex: "none", height: "100%", boxSizing: "border-box", background: C.bg, borderRight: `1px solid ${C.border}`, color: C.text, font: "13px system-ui", display: "flex", flexDirection: "column", padding: collapsed ? "12px 8px" : 12, gap: 8 }}>
      <div style={{ display: "flex", flexDirection: collapsed ? "column" : "row", alignItems: "center", gap: 6, color: C.muted, fontSize: 14, fontWeight: 600 }}>
        <img src={logo} width={20} height={20} alt="" style={{ filter: theme === "dark" ? "invert(0.9)" : "none" }} />
        {!collapsed && <span style={{ flex: 1 }}>Excalibre</span>}
        <button aria-label={theme === "dark" ? "Switch to light theme" : "Switch to dark theme"} style={icon(C)} onClick={toggleTheme}>
          <svg {...svg}>{theme === "dark" ? <><circle cx="8" cy="8" r="3" /><path d="M8 1v2M8 13v2M1 8h2M13 8h2M3 3l1.4 1.4M11.6 11.6L13 13M3 13l1.4-1.4M11.6 4.4L13 3" /></> : <path d="M13 9.5A5.5 5.5 0 0 1 6.5 3 5.5 5.5 0 1 0 13 9.5z" />}</svg>
        </button>
        <button aria-label={collapsed ? "Expand sidebar" : "Collapse sidebar"} style={icon(C)} onClick={collapse}>
          <svg {...svg}><path d={collapsed ? "M6 3l5 5-5 5" : "M10 3L5 8l5 5"} /></svg>
        </button>
      </div>
      {!collapsed && <>
      <div style={{ display: "flex", gap: 8 }}>
        <button style={{ ...btn(C, off), background: C.accent, color: C.accentText }} disabled={off} onClick={() => bridge.newFile()}>New file</button>
        <button style={btn(C, off)} disabled={off} onClick={() => bridge.openFile()}>Open file</button>
      </div>
      <div style={{ height: 52, flex: "none", color: C.err, fontSize: 12, display: "flex", gap: 6, overflow: "hidden" }}>
        {banner && <><span style={{ flex: 1 }}>{banner}</span><button aria-label="Dismiss" onClick={() => setDismissed(banner)} style={{ border: 0, background: "none", color: C.err, cursor: "pointer" }}>×</button></>}
      </div>
      <div style={{ flex: 1, overflowY: "auto" }}>
        {vm && vm.sections.length === 0 && <div style={{ color: C.muted }}>No files yet</div>}
        {vm?.sections.map((s) => (
          <div key={s.header}>
            <div style={{ color: C.muted, margin: "8px 0 4px" }}>{s.header}</div>
            {s.rows.map((r) => (
              <button key={r.path} aria-label={r.label} onClick={() => bridge.openPath(r.path)}
                style={{ display: "block", width: "100%", textAlign: "left", border: 0, borderRadius: 6, padding: "6px 8px", marginBottom: 2, font: "inherit", cursor: "pointer", background: r.active ? C.row : "transparent", color: r.active ? C.rowText : C.text }}>
                <div>{r.label}</div>
                <div style={{ fontSize: 11, color: C.muted }}>{r.count} elements · {ago(r.opened_at)}</div>
                {r.err && <div style={{ fontSize: 11, color: C.err }}>{r.err}</div>}
              </button>
            ))}
          </div>
        ))}
      </div>
      <div style={{ flex: "none", fontSize: 11, color: st.s === "failed" ? C.err : C.muted }}>
        {st.s === "saving" ? "Saving…" : st.s === "failed" ? "Couldn't save · retrying" : st.s === "saved" ? `Saved · ${ago(st.at / 1000)}` : ""}
      </div>
      </>}
      {collapsed && <>
        <div style={{ flex: 1 }} />
        <div title={st.s} style={{ alignSelf: "center", width: 6, height: 6, borderRadius: 3, background: st.s === "failed" ? C.err : C.muted, opacity: st.s === "idle" ? 0 : 1 }} />
      </>}
    </aside>
  );
}
