#!/bin/zsh
# Three accounts on the Convex dev deployment (`npm run dev` must have run once):
#   alice@test.local / password123   @alice   follows bob (accepted, both ways)
#   bob@test.local   / password123   @bob     follows carol (accepted); on carol's close list
#   carol@test.local / password123   @carol   does not know alice
# Safe to rerun: an existing account is signed in instead of signed up.
set -euo pipefail
cd "$(dirname "$0")/.."

account() { # email password
  local out
  out=$(npx convex run auth:signIn "{\"provider\":\"password\",\"params\":{\"email\":\"$1\",\"password\":\"$2\",\"flow\":\"signUp\"}}" 2>&1) \
    || out=$(npx convex run auth:signIn "{\"provider\":\"password\",\"params\":{\"email\":\"$1\",\"password\":\"$2\",\"flow\":\"signIn\"}}" 2>&1) \
    || { echo "could not sign in $1: $out"; exit 1; }
  echo "  $1"
}

echo "accounts"
account alice@test.local password123
account bob@test.local password123
account carol@test.local password123

echo "graph"
npx convex run seed:graph '{}'
