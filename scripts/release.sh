#!/bin/zsh
# Build Doorbell.dmg for GitHub releases. Bakes `.env.production` into the app bundle.
#
#   scripts/deploy-cloud.sh          # once — writes .env.production
#   scripts/release.sh               # build/Doorbell.dmg
#   scripts/release.sh --publish     # build + private-beta GitHub release
#   DOORBELL_DISTRIBUTION=signed scripts/release.sh --publish  # optional signed channel
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -f .env.production ]] || {
  cat >&2 <<'EOF'
Missing .env.production.

Run once in a real terminal (browser sign-in):
  scripts/deploy-cloud.sh

Then commit .env.production and run this again.
EOF
  exit 1
}

if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

release_commit=$(git rev-parse HEAD)
if [[ "${1:-}" == "--publish" ]]; then
  [[ -z "$(git status --porcelain)" ]] || { echo "Commit the reviewed release candidate before building for publication." >&2; exit 1; }
fi

OUT="${DOORBELL_BUILD_DIR:-build}"
OUT="${OUT:A}"
mkdir -p "$OUT"
cp .env.production "$OUT/release.env"

echo "→ build Doorbell.app (release)"
tag="v$(date +%Y.%m.%d-%H%M)-$(git rev-parse --short HEAD)"
export DOORBELL_VERSION="$tag"
DOORBELL_BUILD_DIR="$OUT" DOORBELL_CONFIG_FILE="$OUT/release.env" scripts/bundle.sh release

echo "→ pack Doorbell.dmg"
staging=$(mktemp -d "$OUT/release-staging.XXXXXX")
trap 'rm -rf "$staging"' EXIT
ditto "$OUT/Doorbell.app" "$staging/Doorbell.app"
cp scripts/Install-Doorbell.command scripts/lib/install-dmg.sh "$staging/"
chmod +x "$staging/Install-Doorbell.command"
# A configured Developer ID signs in bundle.sh; notarization is explicit and repeatable.
if [[ -n "${DOORBELL_NOTARY_PROFILE:-}" ]]; then
  ditto -c -k --keepParent "$OUT/Doorbell.app" "$staging/notarize.zip"
  xcrun notarytool submit "$staging/notarize.zip" --keychain-profile "$DOORBELL_NOTARY_PROFILE" --wait
  rm "$staging/notarize.zip"
  xcrun stapler staple "$staging/Doorbell.app"
  xcrun stapler validate "$staging/Doorbell.app"
fi
hdiutil create -volname Doorbell -srcfolder "$staging" -ov -format UDZO "$OUT/Doorbell.dmg" >/dev/null
(cd "$OUT" && shasum -a 256 Doorbell.dmg > Doorbell.dmg.sha256)
echo "   $OUT/Doorbell.dmg + Doorbell.dmg.sha256"

if [[ "${1:-}" == "--publish" ]]; then
  [[ -z "$(git status --porcelain)" ]] || { echo "Commit the reviewed release candidate before publishing." >&2; exit 1; }
  [[ "$(git rev-parse HEAD)" == "$release_commit" ]] || { echo "Source commit changed during the build. Rebuild before publishing." >&2; exit 1; }
  codesign --verify --deep --strict "$staging/Doorbell.app"
  distribution="${DOORBELL_DISTRIBUTION:-private-beta}"
  if [[ "$distribution" == private-beta ]]; then
    codesign -dv --verbose=4 "$staging/Doorbell.app" 2>&1 | /usr/bin/grep -F -x 'Signature=adhoc' >/dev/null || {
      echo 'Private-beta publishing expects a valid ad-hoc build; use DOORBELL_DISTRIBUTION=signed for a signed release.' >&2; exit 1;
    }
    notes="Doorbell for Apple silicon Macs. Install: https://doorbellnotch.vercel.app — the app updates itself when you open it."
  elif [[ "$distribution" == signed ]]; then
    spctl --assess --type execute "$staging/Doorbell.app"
    notes="Doorbell macOS app — signed release with Fresh Ring updates. Install: https://doorbellnotch.vercel.app"
  else
    echo 'Choose DOORBELL_DISTRIBUTION=private-beta or signed.' >&2; exit 1
  fi
  command -v gh >/dev/null 2>&1 || { echo "Install GitHub CLI: brew install gh" >&2; exit 1; }
  echo "→ gh release create $tag"
  gh release create --repo vagdotdev/doorbell --target "$release_commit" "$tag" "$OUT/Doorbell.dmg" "$OUT/Doorbell.dmg.sha256" --title "Doorbell $tag" --notes "$notes"
  echo "   https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/releases/latest"
fi
