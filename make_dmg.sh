#!/bin/bash
set -e

APP_NAME="Заметки"
BUILD_DIR="/tmp/notes_dmg_build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
DMG_PATH="/Users/egor/.gemini/antigravity/scratch/my_notes/Notes-v1.0.0.dmg"

rm -rf "$BUILD_DIR" "$DMG_PATH"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

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
    <string>Заметки</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
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

ln -s /Applications "$BUILD_DIR/Applications"

hdiutil create -volname "$APP_NAME" -srcfolder "$BUILD_DIR" -ov -format UDZO "$DMG_PATH"
echo "DMG created at $DMG_PATH"
ls -lh "$DMG_PATH"
