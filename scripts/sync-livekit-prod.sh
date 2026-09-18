#!/usr/bin/env zsh
# Verify LiveKit Cloud credentials, then push them to the production Convex deployment.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f .env.secrets ]] || { echo "Missing .env.secrets (see .env.secrets.example)." >&2; exit 1; }
set -a; source .env.secrets; set +a
for key in LIVEKIT_URL LIVEKIT_API_KEY LIVEKIT_API_SECRET; do
  [[ -n "${(P)key:-}" ]] || { echo "Missing $key in .env.secrets" >&2; exit 1; }
done

echo "→ verify LiveKit credentials"
node scripts/verify-livekit.mjs

echo "→ push to Convex production"
npx convex env set --prod "LIVEKIT_URL=${LIVEKIT_URL}"
npx convex env set --prod "LIVEKIT_PUBLIC_URL=${LIVEKIT_PUBLIC_URL:-$LIVEKIT_URL}"
npx convex env set --prod "LIVEKIT_API_KEY=${LIVEKIT_API_KEY}"
npx convex env set --prod "LIVEKIT_API_SECRET=${LIVEKIT_API_SECRET}"
echo "Done. LiveKit is live on production."
