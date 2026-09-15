#!/bin/zsh
# Walk the notch through every scriptable state, then leave the hallway open.
# Ctrl-C stops the current beat; the leftover process is the last one (hallway).

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BIN="$ROOT/.build/debug/DoorbellApp"
BEAT="${DOORBELL_DEMO_BEAT:-12}"

echo "Doorbell demo — look at the notch at the top of the screen."
echo "Building…"
swift build --product DoorbellApp

stop() {
  pkill -f '/DoorbellApp$' 2>/dev/null || pkill -f 'DoorbellApp$' 2>/dev/null || true
  sleep 0.4
}

run() {
  local label="$1"
  shift
  stop
  echo ""
  echo "→ $label"
  env DOORBELL_MOCK_RESET=1 "$@" "$BIN" >/tmp/doorbell-demo.log 2>&1 &
  sleep "$BEAT"
}

trap 'echo ""; echo "(leaving whatever is on screen)"; exit 0' INT

run "1/8 idle door (dark pill)"
run "2/8 hallway" DOORBELL_START_EXPANDED=1
run "3/8 search" DOORBELL_START_MODE=search
run "4/8 follow requests" DOORBELL_START_MODE=requests
run "5/8 settings" DOORBELL_START_MODE=settings
run "6/8 visiting Priya" DOORBELL_START_MODE=visit:priya
run "7/8 Arjun knocks — bounce + peephole" DOORBELL_SIMULATE=knock:arjun
run "8/8 Arjun walks in — room window" DOORBELL_SIMULATE=walkin:arjun

stop
echo ""
echo "→ hallway stays open. Hover the notch, click doors, right-click to simulate."
echo "   Stop with: pkill -f DoorbellApp"
env DOORBELL_MOCK_RESET=1 DOORBELL_START_EXPANDED=1 "$BIN" >/dev/null 2>&1 &
disown
echo "Done. Hallway is running."
