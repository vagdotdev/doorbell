#!/bin/zsh
# Shared helpers for install / update. Source from other scripts; do not run directly.

doorbell_require_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || {
    echo "Doorbell is macOS only." >&2
    exit 1
  }
}

doorbell_repo_slug() {
  local repo="${DOORBELL_REPO:-https://github.com/vagdotdev/doorbell.git}"
  repo="${repo%.git}"
  repo="${repo#https://github.com/}"
  repo="${repo#http://github.com/}"
  print -r -- "$repo"
}

doorbell_release_dmg_url() {
  if [[ -n "${DOORBELL_DMG_URL:-}" ]]; then
    print -r -- "$DOORBELL_DMG_URL"
    return 0
  fi
  print -r -- "https://github.com/$(doorbell_repo_slug)/releases/latest/download/Doorbell.dmg"
}

doorbell_require_toolchain() {
  if [[ -n "${DEVELOPER_DIR:-}" && -d "$DEVELOPER_DIR" ]]; then
    export DEVELOPER_DIR
  elif [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  fi

  if ! xcode-select -p >/dev/null 2>&1; then
    cat >&2 <<'EOF'
Xcode command-line tools are required.

  xcode-select --install

Or install Xcode from the App Store, open it once, then run this again.
EOF
    exit 1
  fi
  if ! swift build --version >/dev/null 2>&1; then
    cat >&2 <<'EOF'
Swift is not available yet.

Open Xcode once so it finishes setup, then run this again.
EOF
    exit 1
  fi
}

# Source updates never discard local work.
doorbell_sync_repo() {
  local branch="${DOORBELL_BRANCH:-main}" remote="${DOORBELL_REMOTE:-origin}"
  if [[ -n "$(git status --porcelain)" ]]; then
    echo 'Local changes found. Commit or stash them before updating from source.' >&2
    return 1
  fi
  git fetch "$remote" "$branch"
  git merge --ff-only "$remote/$branch"
}

doorbell_pick_config() {
  SOURCE="${DOORBELL_CONFIG_FILE:-}"
  if [[ -n "$SOURCE" ]]; then
    [[ -f "$SOURCE" ]] || { echo "Missing config: $SOURCE" >&2; exit 1; }
    return 0
  fi
  if [[ "${DOORBELL_USE_LOCAL:-}" == "1" && -f .env ]]; then
    SOURCE=.env
  elif [[ -f .env.production ]]; then
    SOURCE=.env.production
  elif [[ -f .env.production.example ]]; then
    echo "No .env.production yet. The repo owner runs scripts/deploy-cloud.sh and commits it." >&2
    echo "For local dev on this Mac: DOORBELL_USE_LOCAL=1 DOORBELL_FROM_SOURCE=1 scripts/install.sh" >&2
    exit 1
  elif [[ -f .env ]]; then
    SOURCE=.env
  else
    cat >&2 <<'EOF'
No backend config found.

Production (friends, anywhere):
  owner runs scripts/deploy-cloud.sh once, scripts/release.sh --publish, then reinstall.

This Mac only (dev):
  npm run dev
  scripts/setup-local.sh --quick
  DOORBELL_USE_LOCAL=1 DOORBELL_FROM_SOURCE=1 scripts/install.sh
EOF
    exit 1
  fi
}

doorbell_write_install_env() {
  mkdir -p build
  cp "$SOURCE" build/install.env
  if [[ "${DOORBELL_USE_LOCAL:-0}" == 1 ]]; then export DOORBELL_ALLOW_LOCAL=1; fi
}

doorbell_install_app_bundle() {
  DOORBELL_CONFIG_FILE=build/install.env scripts/bundle.sh release
  source scripts/lib/install-dmg.sh
  doorbell_install_bundle "$PWD/build/Doorbell.app"
}

doorbell_install_from_release() {
  source "$(dirname "${(%):-%x}")/install-dmg.sh"
  doorbell_install_from_dmg_url "$(doorbell_release_dmg_url)"
}

doorbell_install_from_source() {
  local repo="${DOORBELL_REPO:-https://github.com/vagdotdev/doorbell.git}"
  local dir="${DOORBELL_DIR:-$HOME/Doorbell}"

  if [[ -d .git && -f scripts/bundle.sh ]]; then
    dir="$PWD"
  elif [[ ! -d "$dir/.git" ]]; then
    echo "→ clone $repo"
    git clone "$repo" "$dir"
  fi
  cd "$dir"

  doorbell_require_toolchain
  doorbell_sync_repo
  doorbell_pick_config
  doorbell_write_install_env
  doorbell_install_app_bundle
}
