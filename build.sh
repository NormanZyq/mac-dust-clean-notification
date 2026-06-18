#!/usr/bin/env bash
# build.sh — Build CleanNotificationMac.app from SwiftPM
#
# Usage:
#   ./build.sh                    # release build
#   ./build.sh debug              # debug build
#   ./build.sh clean              # remove build/ directory
#   ./build.sh --arch arm64       # build for one architecture

set -euo pipefail

CONFIG="release"
ARCH=""

while [[ $# -gt 0 ]]; do
    case "${1:-}" in
        debug)
            CONFIG="debug"
            shift
            ;;
        clean)
            rm -rf build .build
            echo "Cleaned build/ and .build/"
            exit 0
            ;;
        --arch)
            if [[ $# -lt 2 ]]; then
                echo "Usage: ./build.sh [debug|clean] [--arch arm64|x86_64]" >&2
                exit 1
            fi
            ARCH="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: ./build.sh [debug|clean] [--arch arm64|x86_64]" >&2
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            echo "Usage: ./build.sh [debug|clean] [--arch arm64|x86_64]" >&2
            exit 1
            ;;
    esac
done

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="CleanNotificationMac"
BUNDLE_ID="com.local.clean-notification-mac"
BUILD_DIR="$ROOT/build"

SUFFIX=""
if [[ -n "$ARCH" ]]; then
    SUFFIX="-$ARCH"
fi

APP_DIR="$BUILD_DIR/$APP_NAME$SUFFIX.app"

if [[ -n "$ARCH" ]]; then
    echo "==> Building Swift package ($CONFIG, arch: $ARCH)…"
else
    echo "==> Building Swift package ($CONFIG)…"
fi

if [[ -n "$ARCH" ]]; then
    swift build -c "$CONFIG" --arch "$ARCH"
else
    swift build -c "$CONFIG"
fi

if [[ -n "$ARCH" ]]; then
    BIN_PATH="$(swift build -c "$CONFIG" --arch "$ARCH" --show-bin-path)/$APP_NAME"
else
    BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"
fi
if [[ ! -x "$BIN_PATH" ]]; then
    echo "ERROR: Built binary not found at $BIN_PATH" >&2
    exit 1
fi

echo "==> Assembling .app bundle…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

# Copy Info.plist
cp "$ROOT/Sources/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

# Copy entitlements (not embedded into bundle, used at sign step)
cp "$ROOT/Sources/Resources/CleanNotificationMac.entitlements" \
   "$APP_DIR/Contents/Resources/CleanNotificationMac.entitlements"

# Copy localized .lproj bundles.
cp -R "$ROOT/Sources/Resources/"*.lproj "$APP_DIR/Contents/Resources/"

# Copy app icon (.icns) into Contents/Resources so macOS picks it up
# via CFBundleIconName in Info.plist. Skip silently if the icon was never
# generated — the app will fall back to the generic app icon.
if [[ -f "$ROOT/Sources/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Sources/Resources/AppIcon.icns" \
       "$APP_DIR/Contents/Resources/AppIcon.icns"
    echo "==> App icon installed."
else
    echo "==> WARNING: AppIcon.icns not found at Sources/Resources/AppIcon.icns"
    echo "    The app will use the default generic icon."
fi

# Ad-hoc code sign
echo "==> Ad-hoc codesigning…"
codesign --force --deep --sign - \
    --entitlements "$ROOT/Sources/Resources/CleanNotificationMac.entitlements" \
    "$APP_DIR"

echo ""
echo "✓ Built: $APP_DIR"
echo ""
echo "To install:"
echo "  cp -R \"$APP_DIR\" /Applications/"
echo ""
echo "First launch note: macOS may warn about an unidentified developer."
echo "Open System Settings > Privacy & Security, click 'Open Anyway' once."
