#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="Lumina"
VERSION="${VERSION:-1.0.2}"
OUTPUT_DIR="${OUTPUT_DIR:-dist}"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/LuminaDMG.XXXXXX")"
ARM_BUILD="$WORK_DIR/arm64"
INTEL_BUILD="$WORK_DIR/x86_64"
UNIVERSAL_APP="$WORK_DIR/universal/$APP_NAME.app"
DMG_ROOT="$WORK_DIR/dmg-root"
OUTPUT_PATH="$OUTPUT_DIR/$DMG_NAME"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

build_architecture() {
    local architecture="$1"
    local destination="$2"

    echo "Building $APP_NAME $VERSION for $architecture..."
    BUILD_DIR="$destination" \
    BUILD_TARGET="$architecture-apple-macosx13.0" \
    APP_VERSION="$VERSION" \
    bash build.sh
}

build_architecture arm64 "$ARM_BUILD"
build_architecture x86_64 "$INTEL_BUILD"

mkdir -p "$(dirname "$UNIVERSAL_APP")"
ditto "$ARM_BUILD/$APP_NAME.app" "$UNIVERSAL_APP"

ARM_BINARY="$ARM_BUILD/$APP_NAME.app/Contents/MacOS/$APP_NAME"
INTEL_BINARY="$INTEL_BUILD/$APP_NAME.app/Contents/MacOS/$APP_NAME"
UNIVERSAL_BINARY="$UNIVERSAL_APP/Contents/MacOS/$APP_NAME"

lipo -create "$ARM_BINARY" "$INTEL_BINARY" -output "$UNIVERSAL_BINARY"
chmod +x "$UNIVERSAL_BINARY"

xattr -cr "$UNIVERSAL_APP"
codesign --force --deep --sign - "$UNIVERSAL_APP"
codesign --verify --deep --strict "$UNIVERSAL_APP"

ARCHITECTURES="$(lipo -archs "$UNIVERSAL_BINARY")"
if [[ "$ARCHITECTURES" != *"arm64"* || "$ARCHITECTURES" != *"x86_64"* ]]; then
    echo "Universal binary verification failed: $ARCHITECTURES" >&2
    exit 1
fi

mkdir -p "$DMG_ROOT"
ditto "$UNIVERSAL_APP" "$DMG_ROOT/$APP_NAME.app"
ln -s /Applications "$DMG_ROOT/Applications"

cat > "$DMG_ROOT/README.txt" <<EOF
Install Lumina
==============

1. Drag Lumina.app into the Applications folder.
2. Make sure BetterDisplay is installed in /Applications.
3. Open Lumina from Applications.

Lumina is currently ad-hoc signed rather than Apple-notarized. On first launch,
macOS may require you to Control-click Lumina, choose Open, and confirm.
EOF

mkdir -p "$OUTPUT_DIR"
rm -f "$OUTPUT_PATH" "$OUTPUT_PATH.sha256"

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_ROOT" \
    -format UDZO \
    -ov \
    "$OUTPUT_PATH"

shasum -a 256 "$OUTPUT_PATH" > "$OUTPUT_PATH.sha256"

hdiutil verify "$OUTPUT_PATH"

echo "Created universal DMG: $OUTPUT_PATH"
echo "Architectures: $ARCHITECTURES"
echo "Checksum: $OUTPUT_PATH.sha256"
