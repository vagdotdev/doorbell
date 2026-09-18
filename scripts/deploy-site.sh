#!/bin/zsh
# Deploy the landing page to Vercel (doorbellnotch.vercel.app).
#
#   scripts/deploy-site.sh
#
# First time: `vercel login`, then run this.
set -euo pipefail
ROOT="$(dirname "$0")/.."
cd "$ROOT/web"
tag=$(curl -fsSL https://api.github.com/repos/vagdotdev/doorbell/releases/latest | python3 -c "import sys,json; print(json.load(sys.stdin).get('tag_name',''))")
if [[ -n "$tag" ]]; then
  python3 - "$tag" <<'PY'
import pathlib, re, sys
path = pathlib.Path("index.html")
text = path.read_text()
tag = sys.argv[1]
text = re.sub(r'(<span id="release-tag">)[^<]*(</span>)', rf"\1{tag}\2", text, count=1)
path.write_text(text)
PY
  echo "→ landing release tag: $tag"
fi
echo "→ vercel deploy"
deploy_out=$(vercel deploy --prod --yes 2>&1) || { echo "$deploy_out" >&2; exit 1; }
echo "$deploy_out"
URL=$(print -r -- "$deploy_out" | grep -Eo 'https://[^ ]+\.vercel\.app' | tail -1)
[[ -n "$URL" ]] || { echo "Could not parse deployment URL." >&2; exit 1; }
vercel alias set "$URL" doorbellnotch.vercel.app
echo "   https://doorbellnotch.vercel.app"
