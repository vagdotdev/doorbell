#!/bin/zsh
# Preflight a verified update, then wait for only the requesting installed app.
set -euo pipefail
DMG="${1:?missing dmg path}"
CALLER_PID="${2:?missing caller pid}"
APP="${3:?missing app path}"
EXPECTED="${4:?missing checksum}"
READY="${5:?missing ready signal}"
RELEASE_TAG="${6:?missing release tag}"
QUARANTINE="${DMG:h}/Doorbell.failed.json"
DIR="${0:A:h}"
source "$DIR/install-dmg.sh"

[[ "$RELEASE_TAG" =~ '^v?[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9]{4}-[a-fA-F0-9]{3,40}$' ]] || exit 1
[[ "$CALLER_PID" == <-> && "$CALLER_PID" -gt 1 ]] || exit 1
[[ "$APP" == /Applications/Doorbell.app && ! -L "$APP" ]] || exit 1
[[ "$EXPECTED" =~ '^[a-fA-F0-9]{64}$' && "$READY" == /* && ! -e "$READY" ]] || exit 1
[[ "$(ps -p "$CALLER_PID" -o comm=)" == "$APP/Contents/MacOS/Doorbell" ]] || exit 1
# Another profile/window process using this same installed bundle must remain
# running; postpone before asking the caller to quit rather than killing either.
other_pid="$(ps -ax -o pid= -o comm= | awk -v caller="$CALLER_PID" -v exe="$APP/Contents/MacOS/Doorbell" '$1 != caller && $2 == exe { print $1; exit }')"
[[ -z "$other_pid" ]] || { echo 'Another Doorbell instance is running; update postponed.' >&2; exit 1; }
actual="$(shasum -a 256 "$DMG")"
[[ "${actual%% *}" == "${EXPECTED:l}" ]] || exit 1
doorbell_require_hardware || exit $?

scratch=$(mktemp -d "${TMPDIR:-/tmp}/doorbell-update.XXXXXX") || exit $?
mounted=0
install_started=0
quarantine_written=0
had_quarantine=0
[[ ! -e "$QUARANTINE" ]] || had_quarantine=1
cleanup() {
  local result=$?
  if (( mounted )); then hdiutil detach "$scratch/mount" -quiet 2>/dev/null || true; fi
  rm -rf "$scratch"
  rm -f "$READY"
  if (( quarantine_written && ! install_started && ! had_quarantine )); then rm -f "$QUARANTINE"; fi
  return $result
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
mkdir "$scratch/mount" || exit $?
hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$scratch/mount" -quiet || exit $?
mounted=1
# Continue the installed lineage: the user's ad-hoc beta uses quarantine
# clearing; a signed installation must retain Apple publisher verification.
if [[ "$(doorbell_signature_kind "$APP")" == adhoc ]]; then
  export DOORBELL_ALLOW_UNSIGNED=1
else
  export DOORBELL_ALLOW_UNSIGNED=0
fi
doorbell_validate_app "$scratch/mount/Doorbell.app" || exit $?
doorbell_validate_update "$APP" "$scratch/mount/Doorbell.app" || exit $?
# A checksum can match the wrong uploaded artifact. Never install an older
# bundle that was accidentally attached to a newer GitHub release.
incoming_version="$(/usr/libexec/PlistBuddy -c 'Print :DoorbellReleaseTag' "$scratch/mount/Doorbell.app/Contents/Info.plist")"
[[ "$incoming_version" == "$RELEASE_TAG" ]] || { echo 'Release version does not match the downloaded app.' >&2; exit 1; }
# Persist before asking the app to quit: rollback/relaunch must not immediately
# attempt the same failed candidate again. Failure to persist leaves it open.
quarantine_tmp=$(mktemp "${DMG:h}/.doorbell-failed.XXXXXX") || exit $?
printf '{"tag":"%s","digest":"%s"}\n' "$RELEASE_TAG" "${EXPECTED:l}" > "$quarantine_tmp" || { rm -f "$quarantine_tmp"; exit 1; }
mv -f "$quarantine_tmp" "$QUARANTINE" || { rm -f "$quarantine_tmp"; exit 1; }
quarantine_written=1
: > "$READY"
for _ in {1..120}; do
  [[ "$(ps -p "$CALLER_PID" -o comm= 2>/dev/null || true)" == "$APP/Contents/MacOS/Doorbell" ]] || break
  sleep 0.5
done
if [[ "$(ps -p "$CALLER_PID" -o comm= 2>/dev/null || true)" == "$APP/Contents/MacOS/Doorbell" ]]; then
  echo 'Doorbell stayed open; update postponed.' >&2
  exit 1
fi
export DOORBELL_APP="$APP"
export DOORBELL_AUTOMATIC_UPDATE=1
install_started=1
doorbell_install_bundle "$scratch/mount/Doorbell.app" || {
  result=$?
  # The shared installer has rolled back by the time its subshell returns.
  # Restore the user's running app as well as its files; retain the download/log.
  if [[ -d "$APP" ]]; then doorbell_launch_app "$APP" || true; fi
  exit $result
}
rm -f "$DMG" "$QUARANTINE"
