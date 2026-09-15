#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
scripts/bundle.sh release
mkdir -p build/beta
# Clear only this generated staging directory.
rm -rf build/beta/Doorbell.app
ditto build/Doorbell.app build/beta/Doorbell.app
cp scripts/Install-Doorbell.command 'build/beta/Install Doorbell.command'
chmod +x 'build/beta/Install Doorbell.command'
cat > build/beta/Readme.txt <<'TEXT'
Doorbell private beta
1. Keep Doorbell.app and Install Doorbell.command in the same folder.
2. Open Install Doorbell.command to install in your Applications folder.
3. macOS may require you to approve the installer in Privacy & Security.
This beta is ad-hoc signed, not notarized. The installer removes quarantine only
from the copied Doorbell.app. It does not change system-wide security settings.
Camera, microphone and screen recording still need your permission.
TEXT
ditto -c -k --keepParent build/beta build/Doorbell-beta.zip
shasum -a 256 build/Doorbell-beta.zip > build/Doorbell-beta.zip.sha256
echo 'build/Doorbell-beta.zip'
