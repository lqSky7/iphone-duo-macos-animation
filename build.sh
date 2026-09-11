#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

INFO_PLIST="$DIR/Info.plist"

echo "=== macTilt macOS Build & Install ==="

# Build metadata belongs in the generated bundle, never in the source plist.
# Optional overrides: APP_VERSION=1.2.3 BUILD_NUMBER=42 SIGNING_IDENTITY=<SHA-1>
INSTALL_APP=true
case "${1:-}" in
    "") ;;
    --no-install) INSTALL_APP=false ;;
    *) echo "Usage: $0 [--no-install]" >&2; exit 2 ;;
esac
NEW_VERSION="${APP_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")}"
NEW_BUILD="${BUILD_NUMBER:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"

# 2. Prepare Build Directory
BUILD_DIR="$DIR/build"
APP_BUNDLE="$BUILD_DIR/macTilt.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$BUILD_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# 3. Compile Metal Shaders
echo "▶ Compiling Metal Shaders..."
xcrun -sdk macosx metal -c "$DIR/Sources/FoldShaders.metal" -o "$BUILD_DIR/FoldShaders.air"
xcrun -sdk macosx metallib "$BUILD_DIR/FoldShaders.air" -o "$RESOURCES_DIR/default.metallib"
cp "$DIR/Sources/FoldShaders.metal" "$RESOURCES_DIR/FoldShaders.metal"

# 4. Compile Swift Sources (Universal 2: arm64 + x86_64 targeting macOS 14.0+)
echo "▶ Compiling Swift Application (Universal: arm64 + x86_64 for macOS 14.0+)..."
swiftc -target arm64-apple-macos14.0 -O \
    "$DIR"/Sources/*.swift \
    -o "$BUILD_DIR/macTilt_arm64" \
    -framework AppKit \
    -framework SwiftUI \
    -framework Metal \
    -framework MetalKit \
    -framework ScreenCaptureKit \
    -framework IOKit \
    -framework QuartzCore

swiftc -target x86_64-apple-macos14.0 -O \
    "$DIR"/Sources/*.swift \
    -o "$BUILD_DIR/macTilt_x86_64" \
    -framework AppKit \
    -framework SwiftUI \
    -framework Metal \
    -framework MetalKit \
    -framework ScreenCaptureKit \
    -framework IOKit \
    -framework QuartzCore

lipo -create "$BUILD_DIR/macTilt_arm64" "$BUILD_DIR/macTilt_x86_64" -output "$MACOS_DIR/macTilt"
rm -f "$BUILD_DIR/macTilt_arm64" "$BUILD_DIR/macTilt_x86_64"

# 5. Copy Resources & Plist
cp "$INFO_PLIST" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_VERSION" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$CONTENTS_DIR/Info.plist"

cp -R "$DIR/Resources/ThirdParty" "$RESOURCES_DIR/ThirdParty"

# Generate or copy AppIcon
if [ ! -f "$DIR/Resources/AppIcon.icns" ] && [ -f "$DIR/Resources/AppIcon.png" ]; then
    echo "▶ Generating AppIcon.icns from AppIcon.png..."
    ICONSET="/tmp/AppIcon.iconset"
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    sips -z 16 16     "$DIR/Resources/AppIcon.png" --out "$ICONSET/icon_16x16.png" >/dev/null 2>&1
    sips -z 32 32     "$DIR/Resources/AppIcon.png" --out "$ICONSET/icon_16x16@2x.png" >/dev/null 2>&1
    sips -z 32 32     "$DIR/Resources/AppIcon.png" --out "$ICONSET/icon_32x32.png" >/dev/null 2>&1
    sips -z 64 64     "$DIR/Resources/AppIcon.png" --out "$ICONSET/icon_32x32@2x.png" >/dev/null 2>&1
    sips -z 128 128   "$DIR/Resources/AppIcon.png" --out "$ICONSET/icon_128x128.png" >/dev/null 2>&1
    sips -z 256 256   "$DIR/Resources/AppIcon.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null 2>&1
    sips -z 256 256   "$DIR/Resources/AppIcon.png" --out "$ICONSET/icon_256x256.png" >/dev/null 2>&1
    sips -z 512 512   "$DIR/Resources/AppIcon.png" --out "$ICONSET/icon_256x256@2x.png" >/dev/null 2>&1
    sips -z 512 512   "$DIR/Resources/AppIcon.png" --out "$ICONSET/icon_512x512.png" >/dev/null 2>&1
    sips -z 1024 1024 "$DIR/Resources/AppIcon.png" --out "$ICONSET/icon_512x512@2x.png" >/dev/null 2>&1
    iconutil -c icns "$ICONSET" -o "$DIR/Resources/AppIcon.icns"
    rm -rf "$ICONSET"
fi

if [ -f "$DIR/Resources/AppIcon.icns" ]; then
    cp "$DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$CONTENTS_DIR/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$CONTENTS_DIR/Info.plist"
fi

if [ -d "$DIR/Resources/Untitled.icon" ]; then
    cp -R "$DIR/Resources/Untitled.icon" "$RESOURCES_DIR/Untitled.icon"
fi

if [ -f "$DIR/Resources/default.png" ]; then
    cp "$DIR/Resources/default.png" "$RESOURCES_DIR/default.png"
fi
if [ -f "$DIR/Resources/AppIcon.png" ]; then
    cp "$DIR/Resources/AppIcon.png" "$RESOURCES_DIR/AppIcon.png"
fi
if [ -f "$DIR/Resources/AppIcon.svg" ]; then
    cp "$DIR/Resources/AppIcon.svg" "$RESOURCES_DIR/AppIcon.svg"
fi

# 6. Compile Companion Screen Saver (macTilt.saver - Universal: arm64 + x86_64 for macOS 14.0+)
SAVER_BUNDLE="$BUILD_DIR/macTilt.saver"
echo "▶ Compiling Companion Screen Saver ($SAVER_BUNDLE)..."
rm -rf "$SAVER_BUNDLE"
mkdir -p "$SAVER_BUNDLE/Contents/MacOS" "$SAVER_BUNDLE/Contents/Resources"
cp "$DIR/Resources/ScreenSaver-Info.plist" "$SAVER_BUNDLE/Contents/Info.plist"

swiftc -target arm64-apple-macos14.0 -O -emit-library \
    "$DIR/Sources/ScreenSaver/MacTiltScreenSaverView.swift" \
    "$DIR/Sources/MetalFoldView.swift" \
    "$DIR/Sources/SharedStateManager.swift" \
    -framework ScreenSaver -framework AppKit -framework Metal -framework MetalKit -framework QuartzCore \
    -o "$BUILD_DIR/macTiltSaver_arm64"

swiftc -target x86_64-apple-macos14.0 -O -emit-library \
    "$DIR/Sources/ScreenSaver/MacTiltScreenSaverView.swift" \
    "$DIR/Sources/MetalFoldView.swift" \
    "$DIR/Sources/SharedStateManager.swift" \
    -framework ScreenSaver -framework AppKit -framework Metal -framework MetalKit -framework QuartzCore \
    -o "$BUILD_DIR/macTiltSaver_x86_64"

lipo -create "$BUILD_DIR/macTiltSaver_arm64" "$BUILD_DIR/macTiltSaver_x86_64" -output "$SAVER_BUNDLE/Contents/MacOS/macTiltSaver"
rm -f "$BUILD_DIR/macTiltSaver_arm64" "$BUILD_DIR/macTiltSaver_x86_64"

cp "$RESOURCES_DIR/default.metallib" "$SAVER_BUNDLE/Contents/Resources/default.metallib"
cp "$DIR/Sources/FoldShaders.metal" "$SAVER_BUNDLE/Contents/Resources/"
if [ -f "$DIR/Resources/default.png" ]; then
    cp "$DIR/Resources/default.png" "$SAVER_BUNDLE/Contents/Resources/"
fi

# 7. Codesign App Bundle and Screen Saver
echo "▶ Codesigning Application Bundle & Screen Saver..."
# Explicit identity overrides avoid ambiguous duplicate certificate names.
# Default ad-hoc signing works without a developer account.
codesign --force --deep --sign "$SIGNING_IDENTITY" "$SAVER_BUNDLE"

# Copy signed Screen Saver into app resources
cp -R "$SAVER_BUNDLE" "$RESOURCES_DIR/macTilt.saver"

codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"

# 8. Create Disk Image (DMG) Installer
DMG_OUTPUT="$BUILD_DIR/macTilt.dmg"
echo "▶ Creating Disk Image ($DMG_OUTPUT)..."
DMG_STAGING="/tmp/mactilt_dmg_staging"
rm -rf "$DMG_STAGING" "$DMG_OUTPUT"
mkdir -p "$DMG_STAGING"
cp -R "$APP_BUNDLE" "$DMG_STAGING/macTilt.app"
cp -R "$SAVER_BUNDLE" "$DMG_STAGING/macTilt.saver"
ln -s /Applications "$DMG_STAGING/Applications"
hdiutil create -volname "macTilt" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_OUTPUT" >/dev/null 2>&1
rm -rf "$DMG_STAGING"
if [ "$SIGNING_IDENTITY" != "-" ]; then
    codesign --force --sign "$SIGNING_IDENTITY" "$DMG_OUTPUT" >/dev/null 2>&1
fi
echo "✔ DMG created and signed: $DMG_OUTPUT"

if [ "$INSTALL_APP" = false ]; then
    echo "✔ Build complete: $APP_BUNDLE"
    exit 0
fi

# 9. Install to /Applications
INSTALL_TARGET="/Applications/macTilt.app"
echo "▶ Installing to $INSTALL_TARGET..."

# Kill running instance if exists
pkill -x "macTilt" || true
pkill -x "iPhoneDuo" || true
sleep 0.5

# Remove old installation if exists
if [ -d "$INSTALL_TARGET" ]; then
    rm -rf "$INSTALL_TARGET"
fi
if [ -d "/Applications/iPhoneDuo.app" ]; then
    rm -rf "/Applications/iPhoneDuo.app"
fi

cp -R "$APP_BUNDLE" "$INSTALL_TARGET"

echo "=================================================="
echo "✔ Successfully installed macTilt v${NEW_VERSION} (Build ${NEW_BUILD})"
echo "✔ Location: $INSTALL_TARGET"
echo "=================================================="
