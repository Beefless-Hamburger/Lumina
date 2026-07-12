#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="Lumina"
BUILD_DIR="${BUILD_DIR:-Build}"
BUILD_TARGET="${BUILD_TARGET:-arm64-apple-macosx13.0}"
APP_VERSION="${APP_VERSION:-1.0.2}"
APP_BUILD="${APP_BUILD:-1}"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/LuminaBuild.XXXXXX")"
STAGED_APP="$STAGING_DIR/$APP_NAME.app"
FINAL_APP="$BUILD_DIR/$APP_NAME.app"

cleanup() {
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

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

mkdir -p "$STAGED_APP/Contents/MacOS"
mkdir -p "$STAGED_APP/Contents/Resources"

SOURCES=(
    AppDelegate.swift
    DisplayBackend.swift
    BetterDisplayTransport.swift
    AsyncProcessRunner.swift
    BetterDisplayOutputParser.swift
    AboutView.swift
    BetterDisplayService.swift
    DisplayLogic.swift
    DisplaySleeper.swift
    ShutdownHeartbeatController.swift
    DisplayMonitor.swift
    LuminaApp.swift
    SystemBetterDisplayTransport.swift
    VisualEffectView.swift
)

SWIFT_FLAGS=(
    -swift-version 5
    -warn-concurrency
    -strict-concurrency=complete
)

echo "Compiling Lumina $APP_VERSION for $BUILD_TARGET..."
swiftc "${SOURCES[@]}" \
    -o "$STAGED_APP/Contents/MacOS/$APP_NAME" \
    -target "$BUILD_TARGET" \
    -framework SwiftUI \
    -framework AppKit \
    -framework Combine \
    -O \
    "${SWIFT_FLAGS[@]}"

if [ -f "AppIcon.icns" ]; then
    cp AppIcon.icns "$STAGED_APP/Contents/Resources/"
fi

echo "Creating Info.plist..."
cat > "$STAGED_APP/Contents/Info.plist" <<EOF
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
    <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$APP_BUILD</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
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

chmod +x "$STAGED_APP/Contents/MacOS/$APP_NAME"

# Cloud-synced folders can add extended attributes that codesign rejects.
clean_bundle_metadata "$STAGED_APP"

echo "Signing application..."
codesign --force --deep --sign - "$STAGED_APP"
clean_bundle_metadata "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"

rm -rf "$FINAL_APP"
mkdir -p "$BUILD_DIR"
mv "$STAGED_APP" "$FINAL_APP"

echo "Build complete: $FINAL_APP"
