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

The app ships the MCP sidecar as a standalone binary; no Node needed. Point your MCP client at it:

```json
{ "mcpServers": { "nanodraw": { "command": "/Applications/Nanodraw.app/Contents/MacOS/nanodraw-mcp" } } }
```

```sh
claude mcp add nanodraw -- /Applications/Nanodraw.app/Contents/MacOS/nanodraw-mcp
```

Tools: `add_elements`, `apply_scene`, `get_scene`, `screenshot`, `save_scene`. Nanodraw must be running; the sidecar talks to it on `127.0.0.1:7411` (`EXCALIDRAW_WS_PORT`).

From source: `cd src/app/mcp && npm ci && npm run build`, then use `node src/app/mcp/dist/index.js` as the command.

## Develop

Needs Zig 0.17, Node, and Bun (`bundle.sh` compiles the MCP sidecar with it). See `SRS.md` and `DESIGN.md`.

```sh
cd src/app && zig build test      # Zig tests
cd src/app && zig build           # builds the web bundle and the app
./src/app/scripts/bundle.sh       # zig-out/Nanodraw.app
./src/app/scripts/package.sh      # zig-out/Nanodraw-macos-arm64.dmg
```

Drafts and history live in `~/Library/Application Support/nanodraw`.

## Credits

Icon: abstract shape by Wilson Joseph from [Noun Project](https://thenounproject.com/browse/icons/term/abstract-shape/) (CC BY 3.0), modified.
