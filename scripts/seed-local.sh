#!/bin/zsh
# Three accounts on the local Supabase stack:
#   alice@test.local / password123   @alice   follows bob (accepted, both ways)
#   bob@test.local   / password123   @bob     follows carol (accepted); on carol's close list
#   carol@test.local / password123   @carol   does not know alice
# Enough to walk bob into carol's room, knock as alice, and have bob let her in there.
# Safe to rerun; signs in instead of signing up when the account exists.
set -euo pipefail
cd "$(dirname "$0")/.."

API=http://127.0.0.1:54321
ANON=$(supabase status -o env 2>/dev/null | rg '^ANON_KEY' | sed -E 's/ANON_KEY="(.*)"/\1/')
[ -n "$ANON" ] || { echo "supabase is not running (supabase start)"; exit 1; }
H=(-H "apikey: $ANON" -H "content-type: application/json")

json() { python3 -c "import sys,json; d=json.load(sys.stdin); print($1)"; }

account() { # email password handle name → "token uid"
  local r tok uid
  r=$(curl -s -X POST "$API/auth/v1/signup" $H -d "{\"email\":\"$1\",\"password\":\"$2\"}")
  tok=$(echo "$r" | json 'd.get("access_token","")')
  if [ -z "$tok" ]; then
    r=$(curl -s -X POST "$API/auth/v1/token?grant_type=password" $H -d "{\"email\":\"$1\",\"password\":\"$2\"}")
    tok=$(echo "$r" | json 'd.get("access_token","")')
  fi
  uid=$(echo "$r" | json 'd["user"]["id"]')
  curl -s -o /dev/null -X POST "$API/rest/v1/profiles" $H -H "Authorization: Bearer $tok" \
    -d "{\"id\":\"$uid\",\"handle\":\"$3\",\"display_name\":\"$4\"}"
  echo "$tok $uid"
}

follow() { # from-token from-uid to-token to-uid
  curl -s -o /dev/null -X POST "$API/rest/v1/follows" $H -H "Authorization: Bearer $1" \
    -d "{\"follower_id\":\"$2\",\"followee_id\":\"$4\",\"status\":\"pending\"}"
  curl -s -o /dev/null -X PATCH "$API/rest/v1/follows?follower_id=eq.$2&followee_id=eq.$4" $H \
    -H "Authorization: Bearer $3" -d '{"status":"accepted"}'
}

read ATOK AUID <<< "$(account alice@test.local password123 alice 'Alice Rao')"
read BTOK BUID <<< "$(account bob@test.local password123 bob 'Bob Menon')"
read CTOK CUID <<< "$(account carol@test.local password123 carol 'Carol Iyer')"
follow "$ATOK" "$AUID" "$BTOK" "$BUID"
follow "$BTOK" "$BUID" "$ATOK" "$AUID"
follow "$BTOK" "$BUID" "$CTOK" "$CUID"
curl -s -o /dev/null -X POST "$API/rest/v1/close_friends" $H -H "Authorization: Bearer $CTOK" \
  -d "{\"owner_id\":\"$CUID\",\"member_id\":\"$BUID\"}"

echo "alice=$AUID"
echo "bob=$BUID"
echo "carol=$CUID"
echo "door-token: alice visits bob →" \
  "$(curl -s -X POST "$API/functions/v1/door-token" $H -H "Authorization: Bearer $ATOK" \
       -d '{"door":"bob","intent":"visit"}' | json '{k: v for k, v in d.items() if k != "token"}')"
