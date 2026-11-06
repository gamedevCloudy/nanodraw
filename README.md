# Nanodraw

A small macOS desktop client for [Excalidraw](https://excalidraw.com): a file-history sidebar, the full Excalidraw canvas, auto-save, and an MCP server so AI agents can draw.

nanodraw is a small, lightweight native app ("nano") built on [NanoUI](https://github.com/justrach/nanoui), the Zig UI library.

## Install

```sh
brew tap gamedevCloudy/tools
brew install --cask nanodraw
```

The app is signed ad hoc, not notarized, so macOS may warn on first launch. Right-click the app and choose Open, or run:

```sh
xattr -dr com.apple.quarantine /Applications/Nanodraw.app
```

## MCP

Build the sidecar (`cd src/app/mcp && npm ci && npm run build`) and point your MCP client at `node src/app/mcp/dist/index.js`. Tools: `add_elements`, `apply_scene`, `get_scene`, `screenshot`, `save_scene`. Nanodraw must be running; the sidecar talks to it on `127.0.0.1:7411` (`EXCALIDRAW_WS_PORT`).

## Develop

Needs Zig 0.17 and Node. See `SRS.md` and `DESIGN.md`.

```sh
cd src/app && zig build test      # Zig tests
cd src/app && zig build           # builds the web bundle and the app
./src/app/scripts/bundle.sh       # zig-out/Nanodraw.app
./src/app/scripts/package.sh      # zig-out/Nanodraw-macos-arm64.dmg
```

Drafts and history live in `~/Library/Application Support/nanodraw`.

Logs live in `~/Library/Application Support/nanodraw/logs` (`app.log` for this session, `app.prev.log` for the one before). To report a bug, choose **Copy logs** in the canvas menu or on the sidebar's error banner, then paste.

## Credits

Icon: abstract shape by Wilson Joseph from [Noun Project](https://thenounproject.com/browse/icons/term/abstract-shape/) (CC BY 3.0), modified.
