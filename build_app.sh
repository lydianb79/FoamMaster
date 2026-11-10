#!/bin/zsh
# Builds FoamMaster.app (release) into ./build
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/FoamMaster.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/FoamMaster "$APP/Contents/MacOS/FoamMaster"

# Icon
ICONSET=build/AppIcon.iconset
mkdir -p "$ICONSET"
swift Tools/make_icon.swift build/icon_1024.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
# Channel logo for the About sheet (optional).
if [[ -f Assets/RockFPV_logo.png ]]; then cp Assets/RockFPV_logo.png "$APP/Contents/Resources/"; fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>FoamMaster</string>
  <key>CFBundleDisplayName</key><string>FoamMaster</string>
  <key>CFBundleIdentifier</key><string>com.foammaster.app</string>
  <key>CFBundleExecutable</key><string>FoamMaster</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
# The bundle is recreated on every build: make Finder/Dock pick up the icon again.
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
