#!/bin/zsh
# Owner one-shot: cloud backend → release dmg → GitHub release → redeploy landing page.
#
# Run in Terminal (Convex opens the browser once):
#   scripts/ship.sh
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/deploy-cloud.sh
scripts/release.sh --publish
scripts/deploy-site.sh

echo ""
echo "Friends install with:"
echo "  curl -fsSL https://doorbellnotch.vercel.app/install.sh | zsh"
