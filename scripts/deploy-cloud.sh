#!/usr/bin/env zsh
# Take the backend off this Mac: a Convex cloud project, production deployment, its
# secrets, and `.env.production` for installs. Run in a real terminal — the first step
# opens the browser once to sign in, and Convex may ask which team to use.
#
#   scripts/deploy-cloud.sh
#
# Afterwards: friends install with
#   DOORBELL_JOIN_SECRET=… curl -fsSL …/scripts/install.sh | zsh
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -f .env.secrets ]] || { echo "Missing .env.secrets (see .env.secrets.example)." >&2; exit 1; }
set -a; source .env.secrets; set +a
for key in LIVEKIT_URL LIVEKIT_API_KEY LIVEKIT_API_SECRET; do
  [[ -n "${(P)key:-}" ]] || { echo "Missing $key in .env.secrets" >&2; exit 1; }
done

echo "→ Convex account"
npx convex login status 2>/dev/null | grep -q "Logged in" || npx convex login

# Link this checkout to a cloud project if it isn't already.
if grep -q "^CONVEX_DEPLOYMENT=anonymous" .env.local 2>/dev/null; then
  cp .env.local .env.local.anonymous
  echo "→ kept the local deployment in .env.local.anonymous"
fi
if grep -qE '^CONVEX_DEPLOYMENT=(dev|prod):' .env.local 2>/dev/null; then
  echo "→ project already linked ($(grep '^CONVEX_DEPLOYMENT=' .env.local))"
else
  echo "→ linking cloud project doorbell"
  npx convex dev --once --configure new --project doorbell
fi

echo "→ production deployment"
mkdir -p build
npx convex deploy --yes | tee build/deploy.log
PROD_URL=$(grep -Eo 'https://[a-z0-9-]+\.convex\.cloud' build/deploy.log | head -1)
if [[ -z "$PROD_URL" ]]; then
  # The dashboard link names the deployment; its API URL follows from the name.
  NAME=$(npx convex dashboard --prod --no-open 2>/dev/null | grep -Eo '/d/[a-z0-9-]+' | head -1 | cut -c4-)
  [[ -n "$NAME" ]] && PROD_URL="https://${NAME}.convex.cloud"
fi
[[ -n "$PROD_URL" ]] || { echo "Could not determine the production URL. Check \`npx convex dashboard --prod\`." >&2; exit 1; }

echo "→ production secrets"
node scripts/verify-livekit.mjs
npx convex env set --prod "LIVEKIT_URL=${LIVEKIT_URL}"
npx convex env set --prod "LIVEKIT_PUBLIC_URL=${LIVEKIT_PUBLIC_URL:-$LIVEKIT_URL}"
npx convex env set --prod "LIVEKIT_API_KEY=${LIVEKIT_API_KEY}"
npx convex env set --prod "LIVEKIT_API_SECRET=${LIVEKIT_API_SECRET}"
node scripts/convex-auth-keys.mjs --prod

cat > .env.production <<EOF
# Public client config for installs (scripts/install.sh). No secrets: the join phrase
# travels separately as DOORBELL_JOIN_SECRET.
DOORBELL_BACKEND=convex
CONVEX_URL=${PROD_URL}
EOF
echo "→ .env.production (${PROD_URL})"

echo ""
echo "Done. Commit .env.production, then friends install with:"
echo "  DOORBELL_JOIN_SECRET=${DOORBELL_JOIN_SECRET:-doorbell} curl -fsSL https://raw.githubusercontent.com/vagdotdev/doorbell/main/scripts/install.sh | zsh"
echo "Your own Mac: DOORBELL_CONFIG_FILE=.env.production scripts/install.sh   (or keep .env on the local stack)"
