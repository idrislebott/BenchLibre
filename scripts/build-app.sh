#!/bin/bash
set -euo pipefail
PROJECT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD_ROOT=${BENCHLIBRE_BUILD_ROOT:-"$PROJECT_ROOT/.build"}
APP_OUTPUT=${BENCHLIBRE_APP_OUTPUT:-"$HOME/Library/Caches/BenchLibre/Build/BenchLibre.app"}
case "$APP_OUTPUT" in
  */BenchLibre.app) ;;
  *) printf '%s\n' 'BENCHLIBRE_APP_OUTPUT must end with /BenchLibre.app' >&2; exit 1 ;;
esac
swift build --package-path "$PROJECT_ROOT" --scratch-path "$BUILD_ROOT" -c release
BIN_DIRECTORY=$(swift build --package-path "$PROJECT_ROOT" --scratch-path "$BUILD_ROOT" -c release --show-bin-path)
STAGING_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/benchlibre-package.XXXXXX")
trap 'rm -rf "$STAGING_ROOT"' EXIT
APP="$STAGING_ROOT/BenchLibre.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIRECTORY/BenchLibre" "$APP/Contents/MacOS/BenchLibre"
chmod +x "$APP/Contents/MacOS/BenchLibre"
for resource in "$BIN_DIRECTORY"/*.bundle; do
  [ -d "$resource" ] || continue
  ditto --norsrc --noextattr "$resource" "$APP/Contents/Resources/$(basename "$resource")"
done
swift "$PROJECT_ROOT/scripts/make-icon.swift" "$STAGING_ROOT/AppIcon.iconset"
iconutil -c icns "$STAGING_ROOT/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.benchlibre.mac</string>
<key>CFBundleName</key><string>BenchLibre</string>
<key>CFBundleDisplayName</key><string>BenchLibre</string>
<key>CFBundleExecutable</key><string>BenchLibre</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>LSMultipleInstancesProhibited</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Copyright 2026 BenchLibre contributors. MIT License.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
mkdir -p "$(dirname "$APP_OUTPUT")"
if [ -e "$APP_OUTPUT" ]; then
  PREVIOUS="$APP_OUTPUT.previous.$(date +%s)"
  mv "$APP_OUTPUT" "$PREVIOUS"
  printf 'Previous build preserved: %s\n' "$PREVIOUS"
fi
ditto --norsrc --noextattr "$APP" "$APP_OUTPUT"
# Some synced folders add Finder metadata while copying generated app bundles.
# Remove only signing-incompatible Finder/resource-fork metadata, never security attributes.
xattr -dr com.apple.FinderInfo "$APP_OUTPUT" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$APP_OUTPUT" 2>/dev/null || true
codesign --verify --deep --strict "$APP_OUTPUT"
printf 'Application ready: %s\n' "$APP_OUTPUT"
