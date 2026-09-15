#!/bin/zsh
# Build Doorbell.app from the SwiftPM product.
#
#   scripts/bundle.sh            # release → build/Doorbell.app
#   scripts/bundle.sh debug      # debug configuration
#
# A real bundle (stable identifier, signature) is what makes camera and microphone
# permission stick between launches; a bare executable is asked every time.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=${1:-release}
swift build -c "$CONFIG"
BIN=$(swift build -c "$CONFIG" --show-bin-path)

APP=build/Doorbell.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$BIN/DoorbellApp" "$APP/Contents/MacOS/Doorbell"
cp -R "$BIN/Doorbell_DoorbellApp.bundle" "$APP/Contents/Resources/"
for fw in "$BIN"/*.framework; do
  cp -R "$fw" "$APP/Contents/Frameworks/"
done
# Development config rides along so `open build/Doorbell.app` sees the same
# backend as `swift run`. Local dev only; build/ is gitignored.
[ -f .env ] && cp .env "$APP/Contents/Resources/.env"

# Info.plist: the source of truth, plus the keys only a bundle needs.
cp Sources/DoorbellApp/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleExecutable -string Doorbell "$APP/Contents/Info.plist"
plutil -replace CFBundlePackageType -string APPL "$APP/Contents/Info.plist"
plutil -replace LSMinimumSystemVersion -string 15.0 "$APP/Contents/Info.plist"
plutil -replace NSHighResolutionCapable -bool true "$APP/Contents/Info.plist"

# The binary was linked with @rpath frameworks; point it at Contents/Frameworks.
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Doorbell" 2>/dev/null || true

# Ad-hoc signature: enough for a local, stable TCC identity. Real distribution
# (Developer ID + notarization) comes with Phase 7.
codesign --force --deep --sign - "$APP"

echo "→ $APP"
echo "   open $APP     (or: $APP/Contents/MacOS/Doorbell for logs)"
