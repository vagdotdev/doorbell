#!/bin/zsh
# Private beta installer. Only removes quarantine from this exact copied app.
set -euo pipefail
cd "${0:A:h}"
SOURCE="$PWD/Doorbell.app"
DEST="$HOME/Applications/Doorbell.app"
[[ -d "$SOURCE" ]] || { echo 'Doorbell.app must be beside this installer.'; exit 1; }
if pgrep -x Doorbell >/dev/null; then
  echo 'Quit Doorbell, then run this installer again.'
  exit 1
fi
codesign --verify --deep --strict "$SOURCE"
mkdir -p "$HOME/Applications"
STAGING=$(mktemp -d "$HOME/Applications/.doorbell-install.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
ditto "$SOURCE" "$STAGING/Doorbell.app"
codesign --verify --deep --strict "$STAGING/Doorbell.app"
xattr -dr com.apple.quarantine "$STAGING/Doorbell.app"
# Preserve an existing installation until the replacement is ready.
if [[ -e "$DEST" ]]; then mv "$DEST" "$STAGING/Previous.app"; fi
if ! mv "$STAGING/Doorbell.app" "$DEST"; then
  [[ ! -e "$STAGING/Previous.app" ]] || mv "$STAGING/Previous.app" "$DEST"
  exit 1
fi
open "$DEST"
echo 'Doorbell is installed. Your notch is the door.'
