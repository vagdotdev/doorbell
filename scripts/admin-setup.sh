#!/usr/bin/env zsh
# Configure the /admin dashboard password and the new-signup ntfy topic on a
# Convex deployment. The password is never stored anywhere: only its SHA-256
# goes to the deployment, and the plaintext prints exactly once below.
#
#   scripts/admin-setup.sh            # local dev deployment
#   scripts/admin-setup.sh --prod     # production
#
# Re-run any time to rotate the password. The ntfy topic is kept if it already
# exists (rotating it would silently disconnect your phone); to rotate it too:
#   npx convex env remove [--prod] NTFY_TOPIC && scripts/admin-setup.sh [--prod]
set -euo pipefail
cd "$(dirname "$0")/.."

flag=()
[[ "${1:-}" == "--prod" ]] && flag=(--prod)

password=$(openssl rand -base64 33 | tr -dc 'a-zA-Z0-9' | cut -c1-32)
[[ ${#password} -eq 32 ]] || { echo "Could not generate a password." >&2; exit 1; }
hash=$(printf %s "$password" | openssl dgst -sha256 | awk '{print $NF}')

topic=$(npx convex env get "${flag[@]}" NTFY_TOPIC 2>/dev/null || true)
if [[ -z "$topic" ]]; then
  topic="doorbell-$(openssl rand -hex 12)"
  npx convex env set "${flag[@]}" "NTFY_TOPIC=${topic}"
  echo "→ new ntfy topic set"
else
  echo "→ keeping existing ntfy topic"
fi

npx convex env set "${flag[@]}" "ADMIN_PASSWORD_SHA256=${hash}"
echo "→ admin password hash set"

echo ""
echo "Admin password (shown once — put it in a password manager now):"
echo ""
echo "  ${password}"
echo ""
echo "Dashboard:   https://doorbellnotch.vercel.app/admin"
echo "Signup pings: install the ntfy app, then subscribe to your secret topic:"
echo "  https://ntfy.sh/${topic}"
