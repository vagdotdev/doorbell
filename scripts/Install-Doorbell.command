#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
source "$PWD/install-dmg.sh"
# This DMG is the deliberately ad-hoc private beta. The helper still verifies
# bundle integrity and preserves signed publisher trust on existing installs.
export DOORBELL_ALLOW_UNSIGNED=1
doorbell_install_bundle "$PWD/Doorbell.app"
