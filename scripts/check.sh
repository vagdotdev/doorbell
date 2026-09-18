#!/bin/zsh
# Requires Swift, Node, Docker (local Supabase DB running), and livekit-server.
set -euo pipefail
cd "${0:A:h}/.."
./node_modules/.bin/vitest run
./node_modules/.bin/tsc --noEmit
python3 scripts/test-syntax.py
python3 scripts/test-install.py
python3 scripts/test-update-helper.py
python3 scripts/test-signing-config.py
swift build
swift test
npx --yes deno check --node-modules-dir=none supabase/functions/door-token/index.ts
npx --yes deno test --node-modules-dir=none supabase/functions/door-token/handler_test.ts
python3 scripts/test-client-config.py
python3 scripts/test-database.py
scripts/test-media.sh
python3 scripts/test-convex-live.py
zsh -n scripts/Install-Doorbell.command scripts/package-beta.sh scripts/bundle.sh
