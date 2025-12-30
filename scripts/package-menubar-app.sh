#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/.build/release}"
BIN_NAME="${BIN_NAME:-gobx-menubar}"
APP_NAME="${APP_NAME:-Gobx Menubar}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/dist}"
BUNDLE_ID="${APP_BUNDLE_ID:-me.davelindon.gobx.menubar}"
VERSION="${GOBX_VERSION:-0.0.0}"

if command -v git >/dev/null 2>&1; then
  GIT_SHA="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || true)"
else
  GIT_SHA=""
fi

BUILD_VERSION="${GOBX_BUILD_VERSION:-${GIT_SHA:-0}}"
BIN_PATH="$BUILD_DIR/$BIN_NAME"
RESOURCE_BUNDLE_PATH="${RESOURCE_BUNDLE_PATH:-$BUILD_DIR/gobx_GobxCore.bundle}"
ALT_RESOURCE_BUNDLE_PATH="${ALT_RESOURCE_BUNDLE_PATH:-$BUILD_DIR/gobx_gobx.bundle}"
MENUBAR_BUNDLE_PATH="${MENUBAR_BUNDLE_PATH:-$BUILD_DIR/gobx_gobx-menubar.bundle}"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  echo "Building $BIN_NAME..."
  (cd "$ROOT_DIR" && swift build -c release ${SWIFTPM_PATH_FLAGS:-} ${SWIFT_BUILD_FLAGS:-})
fi

if [[ ! -x "$BIN_PATH" ]]; then
  echo "Missing binary at $BIN_PATH" >&2
  exit 1
fi

APP_DIR="$OUT_DIR/${APP_NAME}.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_PATH" "$MACOS_DIR/$BIN_NAME"
chmod +x "$MACOS_DIR/$BIN_NAME"

bundle_found=0
if [[ -d "$RESOURCE_BUNDLE_PATH" ]]; then
  cp -R "$RESOURCE_BUNDLE_PATH" "$RESOURCES_DIR/"
  cp -R "$RESOURCE_BUNDLE_PATH" "$APP_DIR/"
  bundle_found=1
fi
if [[ -d "$ALT_RESOURCE_BUNDLE_PATH" ]]; then
  cp -R "$ALT_RESOURCE_BUNDLE_PATH" "$RESOURCES_DIR/"
  cp -R "$ALT_RESOURCE_BUNDLE_PATH" "$APP_DIR/"
  bundle_found=1
fi
if [[ "$bundle_found" != "1" ]]; then
  echo "Missing GobxCore resource bundle in $BUILD_DIR" >&2
  exit 1
fi

if [[ -d "$MENUBAR_BUNDLE_PATH" ]]; then
  cp -R "$MENUBAR_BUNDLE_PATH" "$RESOURCES_DIR/"
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$BIN_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

echo "App bundle created at: $APP_DIR"
