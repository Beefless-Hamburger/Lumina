#!/bin/bash
set -euo pipefail

APP_NAME="Lumina"
BUILD_DIR="Build"
BUILD_TARGET="${BUILD_TARGET:-arm64-apple-macosx13.0}"

clean_bundle_metadata() {
    local bundle_path="$1"
    xattr -cr "$bundle_path"
    for _ in 1 2 3; do
        xattr -d com.apple.FinderInfo "$bundle_path" 2>/dev/null || true
        xattr -d 'com.apple.fileprovider.fpfs#P' "$bundle_path" 2>/dev/null || true
        sleep 0.1
    done
    xattr -d com.apple.FinderInfo "$bundle_path" 2>/dev/null || true
    xattr -d 'com.apple.fileprovider.fpfs#P' "$bundle_path" 2>/dev/null || true
}

# Cleanup
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/$APP_NAME.app/Contents/MacOS"
mkdir -p "$BUILD_DIR/$APP_NAME.app/Contents/Resources"

echo "Compiling for $BUILD_TARGET..."
swiftc AppDelegate.swift \
    DisplayBackend.swift \
    BetterDisplayTransport.swift \
    BetterDisplayOutputParser.swift \
    AboutView.swift \
    BetterDisplayService.swift \
    DisplayLogic.swift \
    DisplaySleeper.swift \
    DisplayMonitor.swift \
    LuminaApp.swift \
    SystemBetterDisplayTransport.swift \
    VisualEffectView.swift \
    -o "$BUILD_DIR/$APP_NAME.app/Contents/MacOS/$APP_NAME" \
    -target "$BUILD_TARGET" \
    -framework SwiftUI \
    -framework AppKit \
    -framework Combine \
    -O

# Copy icon
if [ -f "AppIcon.icns" ]; then
    cp AppIcon.icns "$BUILD_DIR/$APP_NAME.app/Contents/Resources/"
fi

echo "Creating Info.plist..."
cat > "$BUILD_DIR/$APP_NAME.app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>io.github.lumina-app.Lumina</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Lumina. All rights reserved.</string>
</dict>
</plist>
EOF

# Ensure it's executable
chmod +x "$BUILD_DIR/$APP_NAME.app/Contents/MacOS/$APP_NAME"

# Cloud-synced folders can add extended attributes that codesign rejects.
clean_bundle_metadata "$BUILD_DIR/$APP_NAME.app"

# Ad-hoc sign the application bundle so macOS trusts it
echo "Signing application..."
codesign --force --deep --sign - "$BUILD_DIR/$APP_NAME.app"
clean_bundle_metadata "$BUILD_DIR/$APP_NAME.app"

echo "Build complete: $BUILD_DIR/$APP_NAME.app"
