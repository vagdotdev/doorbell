#!/bin/zsh
# Deploy the landing page to Vercel (doorbellnotch.vercel.app).
#
#   scripts/deploy-site.sh
#
# First time: `vercel login`, then run this.
set -euo pipefail
cd "$(dirname "$0")/../web"
URL=$(vercel deploy --prod --yes 2>&1 | grep -Eo 'https://doorbell-[a-z0-9]+-vagdevs-projects\.vercel\.app' | head -1)
[[ -n "$URL" ]] && vercel alias set "$URL" doorbellnotch.vercel.app
