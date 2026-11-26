#!/bin/bash
set -e

APP_NAME="FlowNote"
BUILD_DIR="/tmp/notes_dmg_build"
RW_DMG="/tmp/notes_dmg_rw.dmg"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
DMG_PATH="/Users/egor/.gemini/antigravity/scratch/my_notes/FlowNote-v1.1.0.dmg"
MOUNT_DIR="/Volumes/$APP_NAME"

rm -rf "$BUILD_DIR" "$RW_DMG" "$DMG_PATH"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$BUILD_DIR/.background"

swiftc -O -target arm64-apple-macos11.0 macos_native/main.swift -o macos_native/Notes
cp macos_native/Notes "$APP_DIR/Contents/MacOS/Notes"
chmod +x "$APP_DIR/Contents/MacOS/Notes"

cp macos_native/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
cp -r build/web "$APP_DIR/Contents/Resources/web"

cat << 'EOF' > "$APP_DIR/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>ru</string>
    <key>CFBundleExecutable</key>
    <string>Notes</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.sentkid.notes</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>FlowNote</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
</dict>
</plist>
EOF

codesign --force --deep --sign - "$APP_DIR"
ln -s /Applications "$BUILD_DIR/Applications"

# Generate Retina DMG background
swift macos_native/gen_dmg_bg.swift "/tmp"
tiffutil -cathidpicheck /tmp/bg@1x.png /tmp/bg@2x.png -out "$BUILD_DIR/.background/bg.tiff"
rm -f /tmp/bg@1x.png /tmp/bg@2x.png

# Detach any leftover mounted volume with the same name
hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true

# Create writable DMG, style Finder window, then convert to compressed UDZO
hdiutil create -volname "$APP_NAME" -srcfolder "$BUILD_DIR" -ov -format UDRW -fs HFS+ "$RW_DMG"
hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG" -mountpoint "$MOUNT_DIR"

osascript_skipped=true
python3 - << EOF
import os, plistlib
from ds_store import DSStore
from mac_alias import Alias

mount = "$MOUNT_DIR"
app_name = "$APP_NAME"
bg_path = os.path.join(mount, ".background", "bg.tiff")
alias = Alias.for_file(bg_path)

with DSStore.open(os.path.join(mount, ".DS_Store"), "w+") as d:
    d["."]["vSrn"] = ("long", 1)
    d["."]["bwsp"] = {
        "ShowStatusBar": False,
        "ShowPathbar": False,
        "ShowToolbar": False,
        "ShowTabView": False,
        "ShowSidebar": False,
        "SidebarWidth": 0,
        "WindowBounds": "{{200, 200}, {660, 448}}",
    }
    d["."]["icvp"] = {
        "viewOptionsVersion": 1,
        "backgroundType": 2,
        "backgroundImageAlias": alias.to_bytes(),
        "gridSpacing": 100.0,
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        "iconSize": 108.0,
        "textSize": 13.0,
        "labelOnBottom": True,
        "showIconPreview": True,
        "showItemInfo": False,
        "arrangeBy": "none",
    }
    d[f"{app_name}.app"]["Iloc"] = (175, 225)
    d["Applications"]["Iloc"] = (485, 225)
EOF

sync
hdiutil detach "$MOUNT_DIR" -force
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG_PATH"
rm -f "$RW_DMG"

echo "DMG created at $DMG_PATH"
