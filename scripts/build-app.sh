#!/bin/bash
# Build RufusAdvanced.app (universal arm64 + x86_64), then package it as .dmg and .zip.
#
#   scripts/build-app.sh            # release build into ./dist
#   ARCHS="arm64" scripts/build-app.sh   # single architecture (faster)
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh   # real signing
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="RufusAdvanced"
BUNDLE_ID="io.github.hashim1999164.rufusadvanced"
VERSION="$(grep -E 'static let version' Sources/BootKit/Jobs/JobRunner.swift | sed -E 's/.*"(.*)".*/\1/')"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
ARCHS="${ARCHS:-arm64 x86_64}"
DIST="dist"
APP="$DIST/$APP_NAME.app"

echo "==> Building $APP_NAME $VERSION ($BUILD_NUMBER) for: $ARCHS"
rm -rf "$DIST" && mkdir -p "$DIST"

BINS_APP=()
BINS_HELPER=()
for arch in $ARCHS; do
  swift build -c release --arch "$arch" --product RufusAdvanced
  swift build -c release --arch "$arch" --product rufusadv-helper
  dir="$(swift build -c release --arch "$arch" --show-bin-path)"
  BINS_APP+=("$dir/RufusAdvanced")
  BINS_HELPER+=("$dir/rufusadv-helper")
done

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${BINS_APP[@]}" -output "$APP/Contents/MacOS/$APP_NAME"
lipo -create "${BINS_HELPER[@]}" -output "$APP/Contents/MacOS/rufusadv-helper"
cp -R Resources/BootKit "$APP/Contents/Resources/BootKit"
cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 RufusAdvanced contributors. GPLv3. Not affiliated with the Rufus project.</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Disk Image</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>CFBundleTypeExtensions</key>
      <array><string>iso</string><string>img</string><string>dmg</string><string>vhd</string><string>vhdx</string>
             <string>gz</string><string>xz</string><string>zst</string><string>bz2</string><string>zip</string><string>wic</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing"
IDENTITY="${SIGN_IDENTITY:--}"
codesign --force --options runtime --timestamp=none -s "$IDENTITY" "$APP/Contents/MacOS/rufusadv-helper"
codesign --force --options runtime --timestamp=none -s "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP" && echo "    signature OK ($IDENTITY)"

echo "==> Packaging"
ditto -c -k --keepParent "$APP" "$DIST/$APP_NAME-$VERSION-macOS.zip"
STAGE="$DIST/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DIST/$APP_NAME-$VERSION-macOS.dmg" >/dev/null
rm -rf "$STAGE"
(cd "$DIST" && shasum -a 256 *.dmg *.zip > SHA256SUMS.txt)
echo "==> Done:"
ls -la "$DIST"
