#!/bin/zsh
# One-shot install: build Doorbell.app, put it in /Applications, clear quarantine.
#
#   curl -fsSL https://raw.githubusercontent.com/vagdotdev/doorbell/main/scripts/install.sh | zsh
#
# Or, from a clone:
#   scripts/install.sh
set -euo pipefail

REPO="${DOORBELL_REPO:-https://github.com/vagdotdev/doorbell.git}"
DIR="${DOORBELL_DIR:-$HOME/Doorbell}"
APP="/Applications/Doorbell.app"

if [[ ! -d "$DIR/.git" ]]; then
  git clone "$REPO" "$DIR"
fi
cd "$DIR"
git pull --ff-only || true

# Node bits for Convex (optional for the mock; needed for the real backend).
if command -v npm >/dev/null 2>&1; then
  npm install --silent
fi

scripts/bundle.sh release

rm -rf "$APP"
cp -R build/Doorbell.app "$APP"
xattr -cr "$APP"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "Installed $APP"
echo "Open with: open $APP"
open "$APP"
