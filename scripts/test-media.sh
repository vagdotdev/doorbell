#!/bin/zsh
# Real SDK connections against our own disposable, loopback-only LiveKit server.
set -euo pipefail
cd "${0:A:h}/.."
command -v livekit-server >/dev/null
mkdir -p .context
MEDIA_DIR=$(mktemp -d "$PWD/.context/media-test.XXXXXX")
python3 - <<'PY'
import socket
for port, kind in [(17900,socket.SOCK_STREAM),(17901,socket.SOCK_STREAM),(17902,socket.SOCK_DGRAM)]:
    with socket.socket(socket.AF_INET,kind) as sock: sock.bind(('127.0.0.1',port))
PY
cat > "$MEDIA_DIR/livekit.yaml" <<'YAML'
port: 17900
rtc:
  tcp_port: 17901
  udp_port: 17902
  use_external_ip: false
YAML
livekit-server --dev --config "$MEDIA_DIR/livekit.yaml" --bind 127.0.0.1 --node-ip 127.0.0.1 > "$MEDIA_DIR/server.log" 2>&1 &
MEDIA_PID=$!
trap 'kill "$MEDIA_PID" 2>/dev/null || true; wait "$MEDIA_PID" 2>/dev/null || true; rm -f "$MEDIA_DIR/tokens.json"' EXIT
python3 - <<'PY'
import socket,time
for attempt in range(50):
    try:
        with socket.create_connection(('127.0.0.1',17900), timeout=.1): break
    except OSError: time.sleep(.1)
else: raise SystemExit('Test LiveKit server did not start')
PY
npx --yes deno run --node-modules-dir=none --allow-env --allow-write scripts/media-test-tokens.ts "$MEDIA_DIR/tokens.json"
DOORBELL_MEDIA_TEST_CONFIG="$MEDIA_DIR/tokens.json" swift test --filter LiveKitIntegrationTests
