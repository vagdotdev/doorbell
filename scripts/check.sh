#!/bin/zsh
# Requires Swift, Node, Docker (local Supabase DB running), and livekit-server.
set -euo pipefail
cd "${0:A:h}/.."
swift build
swift test
npx --yes deno check supabase/functions/door-token/index.ts
npx --yes deno test supabase/functions/door-token/handler_test.ts
python3 scripts/test-client-config.py
python3 scripts/test-database.py
scripts/test-media.sh
zsh -n scripts/Install-Doorbell.command scripts/package-beta.sh scripts/bundle.sh
