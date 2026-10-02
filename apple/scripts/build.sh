#!/bin/zsh
# Builds Squish.app into ./build. Requires Xcode (or the Command Line Tools).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Squish.app"
VERSION="1.0"

echo "→ Compiling"
swift build -c release --arch arm64 --arch x86_64 2>&1 | grep -E "error|warning: unre|Compiling|Build" || true
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Squish"
[[ -f "$BIN" ]] || { echo "Build failed"; exit 1; }

echo "→ Bundling"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Squish"
strip -x "$APP/Contents/MacOS/Squish"

if [[ ! -f build/AppIcon.icns ]]; then
    swift scripts/make-icon.swift build/AppIcon.iconset
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
    rm -rf build/AppIcon.iconset
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Squish</string>
    <key>CFBundleDisplayName</key><string>Squish</string>
    <key>CFBundleIdentifier</key><string>app.squish.Squish</string>
    <key>CFBundleExecutable</key><string>Squish</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Compressible file</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.image</string>
                <string>com.adobe.pdf</string>
                <string>public.movie</string>
                <string>public.audio</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1
echo "→ Done: $APP ($(du -sh "$APP" | cut -f1))"
