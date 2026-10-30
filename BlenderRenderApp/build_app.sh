#!/usr/bin/env bash
# Build "BlenderRender.app" and install it in /Applications.
#
#   remote/BlenderRenderApp/build_app.sh [--no-install]
#
# Bundles the PC-side scripts (remote/pc/*.py plus remote/remote_gpu.py and remote/progress.py) so the
# app can install or update them on the render PC by itself.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REMOTE="$(dirname "$HERE")"
# Assembled and signed outside ~/Documents: iCloud keeps adding Finder metadata to files there,
# which codesign refuses ("resource fork, Finder information, or similar detritus").
STAGE="$(mktemp -d -t blenderrender-build)"
VERSION="$(cat "$REMOTE/VERSION")"
APP="$STAGE/BlenderRender.app"

cd "$HERE"
swift build -c release 2>&1 | grep -vE "^\[[0-9]+/[0-9]+\]" || true
BIN="$(swift build -c release --show-bin-path)/BlenderRender"
[[ -x "$BIN" ]] || { echo "build failed"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/pc"
cp "$BIN" "$APP/Contents/MacOS/BlenderRender"
cp "$HERE/Resources/pack_inspect.py" "$HERE/Resources/assemble_video.py" "$REMOTE/setup_windows_pc.ps1" "$APP/Contents/Resources/"
cp "$REMOTE"/pc/*.py "$REMOTE/remote_gpu.py" "$REMOTE/progress.py" "$APP/Contents/Resources/pc/"
[[ -f "$HERE/Resources/AppIcon.icns" ]] && cp "$HERE/Resources/AppIcon.icns" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>BlenderRender</string>
    <key>CFBundleDisplayName</key><string>BlenderRender</string>
    <key>CFBundleIdentifier</key><string>com.geysier.blenderrender</string>
    <key>CFBundleExecutable</key><string>BlenderRender</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Blender file</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>CFBundleTypeExtensions</key><array><string>blend</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"

xattr -cr "$APP"  # Finder info / quarantine on copied files makes codesign refuse the bundle
codesign --force --deep -s - "$APP" >/dev/null
rm -rf "$HERE/build" && mkdir -p "$HERE/build" && cp -R "$APP" "$HERE/build/"
echo "built $HERE/build/BlenderRender.app"

if [[ "${1:-}" != "--no-install" ]]; then
    rm -rf "/Applications/BlenderRender.app" "/Applications/Geysier Render.app"
    cp -R "$APP" /Applications/
    echo "installed /Applications/BlenderRender.app"
fi
