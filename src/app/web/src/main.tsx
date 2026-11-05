import { createRoot } from "react-dom/client";
import { Excalidraw, MainMenu } from "@excalidraw/excalidraw";
import "@excalidraw/excalidraw/index.css";
import { bridge } from "./generated/bridge";
import { Sidebar } from "./Sidebar";
import { useEffect, useSyncExternalStore } from "react";
import { attach, onChange, uiOptions } from "./canvas";
import { canvasBg, getTheme, subscribeTheme } from "./theme";

(window as { EXCALIDRAW_ASSET_PATH?: string }).EXCALIDRAW_ASSET_PATH = "/";

function App() {
  const theme = useSyncExternalStore(subscribeTheme, getTheme);
  useEffect(() => { document.body.style.background = canvasBg[theme]; }, [theme]);
  return (
    <div style={{ display: "flex", height: "100%" }}>
      <Sidebar />
      <div style={{ flex: 1, minWidth: 0, height: "100%" }}>
        <Excalidraw theme={theme} excalidrawAPI={attach} onChange={onChange} UIOptions={uiOptions}>
          <MainMenu>
            <MainMenu.Item onSelect={() => bridge.saveAsRequested()}>Save as…</MainMenu.Item>
            <MainMenu.DefaultItems.SaveAsImage />
            <MainMenu.DefaultItems.Help />
          </MainMenu>
        </Excalidraw>
      </div>
    </div>
  );
}

createRoot(document.getElementById("root")!).render(<App />);
