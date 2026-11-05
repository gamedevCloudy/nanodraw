#!/bin/sh
# Builds zig-out/Excalibre-macos-arm64.dmg (+ .sha256) for the Homebrew cask. Signs ad hoc (see bundle.sh);
# set CODESIGN_IDENTITY to sign with a Developer ID instead (not notarized: shortcut, add notarytool when needed).
set -e
cd "$(dirname "$0")/.."
./scripts/bundle.sh >/dev/null
[ -n "${CODESIGN_IDENTITY:-}" ] && codesign --force --deep --timestamp --options runtime --sign "$CODESIGN_IDENTITY" zig-out/Excalibre.app
stage=$(mktemp -d)
cp -R zig-out/Excalibre.app "$stage/"
ln -s /Applications "$stage/Applications"
dmg=zig-out/Excalibre-macos-arm64.dmg
rm -f "$dmg"
hdiutil create -volname Excalibre -srcfolder "$stage" -ov -format UDZO "$dmg" >/dev/null
rm -rf "$stage"
(cd zig-out && shasum -a 256 Excalibre-macos-arm64.dmg > Excalibre-macos-arm64.dmg.sha256)
cat zig-out/Excalibre-macos-arm64.dmg.sha256
