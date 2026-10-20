#!/bin/bash
# Build a Semafor .app bundle in dist/ from the SemaforApp executable product.
# Env contract (adapted from Beacon's packaging, updater machinery removed):
#   APP_NAME VERSION BUILD_NUMBER BUNDLE_ID MIN_SYSTEM_VERSION CODESIGN_IDENTITY
#   BUILD_CONFIGURATION SKIP_DMG ICON_SOURCE_PATH
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="${APP_NAME:-Semafor}"
PRODUCT_NAME="SemaforApp"

VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
BUNDLE_ID="${BUNDLE_ID:-com.timkoopmans.semafor}"
MIN_SYSTEM_VERSION="${MIN_SYSTEM_VERSION:-14.0}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-release}"
SKIP_DMG="${SKIP_DMG:-0}"
ICON_SOURCE_PATH="${ICON_SOURCE_PATH:-$ROOT_DIR/icon.png}"
ICON_NAME="AppIcon"

DIST_DIR="$ROOT_DIR/dist"
APP_PATH="$DIST_DIR/${APP_NAME}.app"
DMG_PATH="$DIST_DIR/${APP_NAME}-${VERSION}.dmg"
ICONSET_DIR="$DIST_DIR/.${ICON_NAME}.iconset"
ICON_NORMALIZED_PATH="$DIST_DIR/.${ICON_NAME}-1024.png"
ICON_RESOURCE_PATH="$APP_PATH/Contents/Resources/${ICON_NAME}.icns"
BIN_PATH="$(swift build -c "$BUILD_CONFIGURATION" --show-bin-path)"
EXECUTABLE_PATH="$BIN_PATH/$PRODUCT_NAME"
INFO_PLIST_PATH="$APP_PATH/Contents/Info.plist"

cleanup() {
  rm -rf "$ICONSET_DIR" "$ICON_NORMALIZED_PATH"
}
trap cleanup EXIT

generate_app_icon() {
  if [[ ! -f "$ICON_SOURCE_PATH" ]]; then
    return
  fi

  echo "Generating app icon from $ICON_SOURCE_PATH..."
  mkdir -p "$ICONSET_DIR"
  cp "$ICON_SOURCE_PATH" "$ICON_NORMALIZED_PATH"

  # Normalize arbitrary PNG input into square sizes for the .icns asset set.
  sips -Z 1024 "$ICON_NORMALIZED_PATH" >/dev/null
  sips -p 1024 1024 "$ICON_NORMALIZED_PATH" >/dev/null

  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_NORMALIZED_PATH" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    sips -z "$retina_size" "$retina_size" "$ICON_NORMALIZED_PATH" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
  done

  iconutil --convert icns --output "$ICON_RESOURCE_PATH" "$ICONSET_DIR"
}

rm -rf "$APP_PATH" "$DMG_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"

echo "Building $BUILD_CONFIGURATION binary..."
swift build -c "$BUILD_CONFIGURATION" --product "$PRODUCT_NAME"

if [[ ! -x "$EXECUTABLE_PATH" ]]; then
  echo "Expected executable not found at $EXECUTABLE_PATH" >&2
  exit 1
fi

cp "$EXECUTABLE_PATH" "$APP_PATH/Contents/MacOS/$APP_NAME"
chmod 755 "$APP_PATH/Contents/MacOS/$APP_NAME"

generate_app_icon

ICON_PLIST_ENTRY=""
if [[ -f "$ICON_RESOURCE_PATH" ]]; then
  ICON_PLIST_ENTRY=$'  <key>CFBundleIconFile</key>\n  <string>'"$ICON_NAME"$'</string>\n'
fi

cat > "$INFO_PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
${ICON_PLIST_ENTRY}  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key>
  <string>${MIN_SYSTEM_VERSION}</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

echo "Signing app bundle..."
if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
  codesign --force --deep --sign - "$APP_PATH"
else
  codesign --force --deep --timestamp --options runtime --sign "$CODESIGN_IDENTITY" "$APP_PATH"
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
plutil -lint "$INFO_PLIST_PATH"

if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
  echo "Ad-hoc signed: fine for your own Mac, not for distribution."
fi

echo "App bundle: $APP_PATH"

if [[ "$SKIP_DMG" == "1" ]]; then
  echo "Skipping DMG creation."
  exit 0
fi

echo "Creating plain DMG archive..."
STAGING="$DIST_DIR/.dmg-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH" -quiet
rm -rf "$STAGING"
echo "DMG archive: $DMG_PATH"
