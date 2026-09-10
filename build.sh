#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

INFO_PLIST="$DIR/Info.plist"

echo "=== iPhone Duo macOS Build & Install ==="

# 1. Increment Build Number and Version Number
if [ -f "$INFO_PLIST" ]; then
    CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST" 2>/dev/null || echo "0")
    NEW_BUILD=$((CURRENT_BUILD + 1))
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$INFO_PLIST"
    
    CURRENT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST" 2>/dev/null || echo "1.0.0")
    # Split version and increment patch number (e.g., 1.0.0 -> 1.0.1)
    MAJOR=$(echo "$CURRENT_VERSION" | cut -d. -f1)
    MINOR=$(echo "$CURRENT_VERSION" | cut -d. -f2)
    PATCH=$(echo "$CURRENT_VERSION" | cut -d. -f3)
    if [ -z "$PATCH" ]; then PATCH=0; fi
    NEW_PATCH=$((PATCH + 1))
    NEW_VERSION="${MAJOR}.${MINOR}.${NEW_PATCH}"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_VERSION" "$INFO_PLIST"
    
    echo "▶ Updated Version: $CURRENT_VERSION -> $NEW_VERSION"
    echo "▶ Updated Build Number: $CURRENT_BUILD -> $NEW_BUILD"
else
    echo "Warning: Info.plist not found!"
    NEW_VERSION="1.0.0"
    NEW_BUILD="1"
fi

# 2. Prepare Build Directory
BUILD_DIR="$DIR/build"
APP_BUNDLE="$BUILD_DIR/iPhoneDuo.app"
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

# 4. Compile Swift Sources
echo "▶ Compiling Swift Application..."
swiftc -O \
    "$DIR"/Sources/*.swift \
    -o "$MACOS_DIR/iPhoneDuo" \
    -framework AppKit \
    -framework SwiftUI \
    -framework Metal \
    -framework MetalKit \
    -framework ScreenCaptureKit \
    -framework IOKit \
    -framework QuartzCore

# 5. Copy Resources & Plist
cp "$INFO_PLIST" "$CONTENTS_DIR/Info.plist"

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
elif [ -d "/Users/ca5/Desktop/Untitled.icon" ]; then
    cp -R "/Users/ca5/Desktop/Untitled.icon" "$RESOURCES_DIR/Untitled.icon"
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

# 6. Codesign App Bundle
echo "▶ Codesigning Application Bundle..."
codesign --force --deep --sign - "$APP_BUNDLE"

# 7. Install to /Applications
INSTALL_TARGET="/Applications/iPhoneDuo.app"
echo "▶ Installing to $INSTALL_TARGET..."

# Kill running instance if exists
pkill -x "iPhoneDuo" || true
sleep 0.5

# Remove old installation if exists
if [ -d "$INSTALL_TARGET" ]; then
    rm -rf "$INSTALL_TARGET"
fi

cp -R "$APP_BUNDLE" "$INSTALL_TARGET"

echo "=================================================="
echo "✔ Successfully installed iPhone Duo v${NEW_VERSION} (Build ${NEW_BUILD})"
echo "✔ Location: $INSTALL_TARGET"
echo "=================================================="
