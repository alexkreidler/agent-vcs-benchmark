#!/usr/bin/env bash
# Install the extra binaries needed by forgejo.sh, followup.sh, and
# followup-network.sh into the same isolated tool tree the other harnesses use.
# Idempotent: re-running only re-fetches what is missing.
set -euo pipefail

BENCH_ROOT=${BENCH_ROOT:-/tmp/vcs-agent-bench}
TOOLS="$BENCH_ROOT/tools"
mkdir -p "$TOOLS/bin" "$TOOLS/lore" "$TOOLS/claw" "$TOOLS/soft-serve" "$TOOLS/twigg" "$TOOLS/oxen"

FORGEJO_VERSION=${FORGEJO_VERSION:-16.0.1}
LORE_VERSION=${LORE_VERSION:-0.8.6}
CLAW_VERSION=${CLAW_VERSION:-0.1.0}
SOFT_VERSION=${SOFT_VERSION:-0.12.2}
OXEN_VERSION=${OXEN_VERSION:-0.53.0}
TWIGG_REF=${TWIGG_REF:-3dd94af}

fetch() { curl -fsSL --retry 3 -o "$1" "$2"; }

# --- Forgejo (forge over HTTP, SQLite backend) ---
if [[ ! -x "$TOOLS/bin/forgejo" ]]; then
  fetch "$TOOLS/bin/forgejo" \
    "https://code.forgejo.org/forgejo/forgejo/releases/download/v${FORGEJO_VERSION}/forgejo-${FORGEJO_VERSION}-linux-amd64"
  chmod +x "$TOOLS/bin/forgejo"
fi
"$TOOLS/bin/forgejo" --version

# --- Lore + Lore server (Epic Games, content-addressed, layered store) ---
if [[ ! -x "$TOOLS/lore/lore" ]]; then
  fetch "$TOOLS/lore/lore.tar.gz" \
    "https://github.com/EpicGames/lore/releases/download/v${LORE_VERSION}/lore-v${LORE_VERSION}-x86_64-unknown-linux-gnu.tar.gz"
  fetch "$TOOLS/lore/loreserver.tar.gz" \
    "https://github.com/EpicGames/lore/releases/download/v${LORE_VERSION}/loreserver-v${LORE_VERSION}-x86_64-unknown-linux-gnu.tar.gz"
  tar -xzf "$TOOLS/lore/lore.tar.gz" -C "$TOOLS/lore"
  tar -xzf "$TOOLS/lore/loreserver.tar.gz" -C "$TOOLS/lore"
  chmod u+x "$TOOLS/lore/lore" "$TOOLS/lore/loreserver"
fi
"$TOOLS/lore/lore" --version
"$TOOLS/lore/loreserver" --version

# --- Claw VCS (intent/agent-native, gRPC sync daemon) ---
if [[ ! -x "$TOOLS/claw/claw-x86_64-unknown-linux-gnu/claw" ]]; then
  fetch "$TOOLS/claw/claw-x86_64-unknown-linux-gnu.tar.xz" \
    "https://github.com/Shree-git/claw-vcs/releases/download/v${CLAW_VERSION}/claw-x86_64-unknown-linux-gnu.tar.xz"
  fetch "$TOOLS/claw/claw.sha256" \
    "https://github.com/Shree-git/claw-vcs/releases/download/v${CLAW_VERSION}/claw-x86_64-unknown-linux-gnu.tar.xz.sha256"
  (cd "$TOOLS/claw" && sha256sum -c claw.sha256)
  tar -xJf "$TOOLS/claw/claw-x86_64-unknown-linux-gnu.tar.xz" -C "$TOOLS/claw"
fi
"$TOOLS/claw/claw-x86_64-unknown-linux-gnu/claw" --version

# --- Soft Serve (lightweight Git host over SSH, SQLite backend) ---
if [[ ! -x "$TOOLS/soft-serve/soft-serve_${SOFT_VERSION}_Linux_x86_64/soft" ]]; then
  fetch "$TOOLS/soft-serve/soft.tar.gz" \
    "https://github.com/charmbracelet/soft-serve/releases/download/v${SOFT_VERSION}/soft-serve_${SOFT_VERSION}_Linux_x86_64.tar.gz"
  tar -xzf "$TOOLS/soft-serve/soft.tar.gz" -C "$TOOLS/soft-serve"
fi
"$TOOLS/soft-serve/soft-serve_${SOFT_VERSION}_Linux_x86_64/soft" --version

# --- Oxen (ML data version control) ---
if [[ ! -x "$TOOLS/oxen/oxen" ]]; then
  fetch "$TOOLS/oxen/oxen.tar.gz" \
    "https://github.com/Oxen-AI/Oxen/releases/download/v${OXEN_VERSION}/oxen-linux-x86_64.tar.gz"
  tar -xzf "$TOOLS/oxen/oxen.tar.gz" -C "$TOOLS/oxen"
fi
"$TOOLS/oxen/oxen" --version

# --- Twigg (Go, stacked-commit VCS; built from source) ---
# Requires a Go toolchain and a checkout of twigg-vc/monorepo at $TWIGG_SRC.
if [[ ! -x "$TOOLS/twigg/tw" ]]; then
  TWIGG_SRC=${TWIGG_SRC:-/tmp/vcs-small-oss-screen/twigg}
  if [[ ! -d "$TWIGG_SRC/tw" ]]; then
    mkdir -p "$(dirname "$TWIGG_SRC")"
    git clone --quiet "https://github.com/twigg-vc/monorepo.git" "$TWIGG_SRC"
    git -C "$TWIGG_SRC" checkout --quiet "$TWIGG_REF"
  fi
  (cd "$TWIGG_SRC/tw" && GOBIN="$TOOLS/twigg" go install)
fi
"$TOOLS/twigg/tw" version || true

printf 'tools installed under %s\n' "$TOOLS"
