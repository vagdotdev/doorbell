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
OUT="${DOORBELL_BUILD_DIR:-build}"
# Validate before spending time compiling. Server secrets are never copied.
mkdir -p "$OUT"
SIGNING_ARGS=()
FOCUS_STATUS=false
if [[ -n "${DOORBELL_SIGN_IDENTITY:-}" ]]; then
  SIGNING_ARGS+=(--signed)
  FOCUS_STATUS=true
fi
[[ -n "${DOORBELL_PROVISION_PROFILE:-}" ]] && SIGNING_ARGS+=(--profile "$DOORBELL_PROVISION_PROFILE")
python3 scripts/signing-config.py prepare "$OUT/signing" "${SIGNING_ARGS[@]}"
CONFIG_ARGS=()
# Debug builds may point at a Convex on this Mac. So may a release, when asked: an
# install for yourself while the cloud deployment doesn't exist yet.
[[ "$CONFIG" == "debug" || -n "${DOORBELL_ALLOW_LOCAL:-}" ]] && CONFIG_ARGS+=(--local)
python3 scripts/client-config.py "${DOORBELL_CONFIG_FILE:-.env}" "$OUT/client.env" "${CONFIG_ARGS[@]}"
swift build -c "$CONFIG"
BIN=$(swift build -c "$CONFIG" --show-bin-path)

APP="$OUT/Doorbell.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$BIN/DoorbellApp" "$APP/Contents/MacOS/Doorbell"
cp "$BIN/DoorbellSwap" "$APP/Contents/MacOS/DoorbellSwap"
# Copy assets into the app bundle. SwiftPM resource bundles bake the build-Mac
# path into the binary; friends must not need /Users/<dev>/.../.build.
cp -R Sources/DoorbellApp/Assets/Portraits "$APP/Contents/Resources/Portraits"
cp -R Sources/DoorbellApp/Assets/Sounds "$APP/Contents/Resources/Sounds"
for fw in "$BIN"/*.framework; do
  cp -R "$fw" "$APP/Contents/Frameworks/"
done
# Only public client configuration is bundled. Debug alone allows local services.
cp "$OUT/client.env" "$APP/Contents/Resources/.env"
# Never ship the developer's .env.local to friends — it points at a dev deployment.
[[ "$CONFIG" == "debug" || -n "${DOORBELL_ALLOW_LOCAL:-}" ]] && \
  [[ -f .env.local ]] && cp .env.local "$APP/Contents/Resources/.env.local"

mkdir -p "$APP/Contents/Resources/scripts"
cp scripts/lib/install-dmg.sh scripts/lib/apply-update.sh "$APP/Contents/Resources/scripts/"
chmod +x "$APP/Contents/Resources/scripts/"*.sh

# The icon Finder, the Dock (during first launch) and the permission prompts show.
# Source of truth: branding/macos-app-icon (approved artwork; regenerate with its export.py).
cp Sources/DoorbellApp/Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Info.plist: the source of truth, plus the keys only a bundle needs.
cp Sources/DoorbellApp/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleIconFile -string AppIcon "$APP/Contents/Info.plist"
plutil -replace CFBundleExecutable -string Doorbell "$APP/Contents/Info.plist"
plutil -replace CFBundlePackageType -string APPL "$APP/Contents/Info.plist"
VERSION="${DOORBELL_VERSION:-0.1-dev}"
# Apple's version fields stay numeric. The signed release tag is independent
# and is checked against GitHub by Fresh Ring before replacement.
MARKETING_VERSION="${DOORBELL_MARKETING_VERSION:-0.1.0}"
if [[ -n "${DOORBELL_BUILD_NUMBER:-}" ]]; then
  BUILD_NUMBER="$DOORBELL_BUILD_NUMBER"
else
  BUILD_NUMBER=$(python3 -c 'from datetime import datetime,date; n=datetime.now(); print("{}.{}.{}".format((n.date()-date(2020,1,1)).days+1,n.hour,n.minute))')
fi
python3 - "$MARKETING_VERSION" "$BUILD_NUMBER" <<'PYVERSION'
import re,sys
assert re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+",sys.argv[1]), 'Invalid marketing version'
assert re.fullmatch(r"[1-9][0-9]{0,3}\.[0-9]{1,2}\.[0-9]{1,2}",sys.argv[2]), 'Invalid build number'
PYVERSION
plutil -replace CFBundleShortVersionString -string "$MARKETING_VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
plutil -replace DoorbellReleaseTag -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace DoorbellFocusStatusEnabled -bool "$FOCUS_STATUS" "$APP/Contents/Info.plist"
plutil -replace LSMinimumSystemVersion -string 15.0 "$APP/Contents/Info.plist"
plutil -replace NSHighResolutionCapable -bool true "$APP/Contents/Info.plist"

# The binary was linked with @rpath frameworks; point it at Contents/Frameworks.
# SwiftPM also injects the local Xcode toolchain rpath — delete machine-local ones.
doorbell_drop_local_rpaths() {
  local bin="$1" path
  [[ -f "$bin" ]] || return 0
  while IFS= read -r path; do
    case "$path" in
      /Applications/Xcode.app/*|/Library/Developer/*|/Users/*)
        /usr/bin/install_name_tool -delete_rpath "$path" "$bin" || return 1
        ;;
    esac
  done < <(/usr/bin/otool -l "$bin" | /usr/bin/awk '/cmd LC_RPATH/{c=1} c && $1=="path"{print $2; c=0}')
}
doorbell_drop_local_rpaths "$APP/Contents/MacOS/Doorbell"
doorbell_drop_local_rpaths "$APP/Contents/MacOS/DoorbellSwap"
/usr/bin/install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Doorbell" 2>/dev/null || true
if /usr/bin/otool -l "$APP/Contents/MacOS/Doorbell" | /usr/bin/awk '/cmd LC_RPATH/{c=1} c && $1=="path"{print $2; c=0}' | /usr/bin/grep -E '^(/Applications/Xcode.app/|/Library/Developer/|/Users/)' >/dev/null; then
  echo 'Doorbell still contains a machine-local rpath.' >&2
  exit 1
fi

# Ad-hoc signed private beta. Fresh-Mac approval and permission persistence
# must be tested; Developer ID/notarization can remove distribution friction later.
if [[ -n "${DOORBELL_SIGN_IDENTITY:-}" ]]; then
  cp "$OUT/signing/embedded.provisionprofile" "$APP/Contents/embedded.provisionprofile"
  for fw in "$APP/Contents/Frameworks"/*.framework; do
    codesign --force --options runtime --timestamp --sign "$DOORBELL_SIGN_IDENTITY" "$fw"
  done
  codesign --force --options runtime --timestamp --sign "$DOORBELL_SIGN_IDENTITY" "$APP/Contents/MacOS/DoorbellSwap"
  codesign --force --options runtime --timestamp --entitlements "$OUT/signing/app.entitlements" --sign "$DOORBELL_SIGN_IDENTITY" "$APP"
else
  for fw in "$APP/Contents/Frameworks"/*.framework; do
    codesign --force --sign - "$fw"
  done
  codesign --force --sign - "$APP/Contents/MacOS/DoorbellSwap"
  codesign --force --entitlements "$OUT/signing/app.entitlements" --sign - "$APP"
  echo "Unsigned beta build: Developer ID + notarization are required for public distribution." >&2
fi
codesign --verify --deep --strict "$APP"
python3 scripts/signing-config.py verify-app "$APP"

echo "→ $APP"
echo "   open $APP     (or: $APP/Contents/MacOS/Doorbell for logs)"
