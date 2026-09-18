#!/bin/zsh
set -euo pipefail
if [[ -f "${0:A:h}/install.sh" ]]; then
  exec zsh "${0:A:h}/install.sh"
fi
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
curl --fail --location --proto '=https' --proto-redir '=https' -o "$scratch/install.sh" https://doorbellnotch.vercel.app/install.sh
zsh "$scratch/install.sh"
