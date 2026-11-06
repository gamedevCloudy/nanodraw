#!/bin/sh
# Builds zig-out/Nanodraw.app from the release binary so macOS shows the name and icon in the Dock and menu bar.
set -e
cd "$(dirname "$0")/.."
zig build -Doptimize=ReleaseSafe
app=zig-out/Nanodraw.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp zig-out/bin/nanodraw "$app/Contents/MacOS/Nanodraw"
cp assets/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Nanodraw</string>
  <key>CFBundleDisplayName</key><string>Nanodraw</string>
  <key>CFBundleIdentifier</key><string>app.nanodraw.Nanodraw</string>
  <key>CFBundleExecutable</key><string>Nanodraw</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>Excalidraw Drawing</string>
    <key>CFBundleTypeExtensions</key><array><string>excalidraw</string></array>
    <key>CFBundleTypeRole</key><string>Editor</string>
  </dict></array>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
P
codesign --force --deep --sign - "$app"
echo "$app"
