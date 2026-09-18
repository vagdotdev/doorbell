#!/bin/zsh
# Default: verified release, no Git or Xcode needed. Source builds are explicit.
set -euo pipefail
if [[ "${DOORBELL_FROM_SOURCE:-0}" == 1 ]]; then
  [[ -f "${0:A:h}/lib/common.sh" ]] || { echo 'Clone the repository to build from source.' >&2; exit 1; }
  source "${0:A:h}/lib/common.sh"
  doorbell_install_from_source
elif [[ -f "${0:A:h}/lib/install-dmg.sh" ]]; then
  source "${0:A:h}/lib/install-dmg.sh"
  doorbell_install_from_dmg_url "${DOORBELL_DMG_URL:-https://github.com/vagdotdev/doorbell/releases/latest/download/Doorbell.dmg}"
else
  scratch=$(mktemp -d)
  trap 'rm -rf "$scratch"' EXIT
  curl --fail --location --proto '=https' --proto-redir '=https' -o "$scratch/install.sh" https://doorbellnotch.vercel.app/install.sh
  zsh "$scratch/install.sh"
fi
