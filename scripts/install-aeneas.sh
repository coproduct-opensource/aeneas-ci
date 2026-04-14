#!/usr/bin/env bash
# install-aeneas.sh — pin and install Charon + Aeneas for a CI runner.
#
# Required env:
#   CHARON_REF — git ref (commit SHA or tag) for AeneasVerif/charon
#   AENEAS_REF — git ref for AeneasVerif/aeneas
#
# Effect:
#   - Installs OCaml + opam (host package or apt fallback)
#   - Builds Charon at $CHARON_REF, drops `charon` on $PATH
#   - Builds Aeneas at $AENEAS_REF, drops `aeneas` on $PATH
#   - Verifies elan + Lean are available (Aeneas needs them at translation time)
#
# Idempotent: if the exact pinned binaries are already in ~/.aeneas-ci-cache,
# skips rebuild. Cache is keyed by ref hash so version bumps invalidate.

set -euo pipefail

if [ -z "${CHARON_REF:-}" ] || [ -z "${AENEAS_REF:-}" ]; then
  echo "::error::CHARON_REF and AENEAS_REF must be set" >&2
  exit 2
fi

CACHE_DIR="$HOME/.aeneas-ci-cache"
CHARON_BIN="$CACHE_DIR/charon-$CHARON_REF/charon"
AENEAS_BIN="$CACHE_DIR/aeneas-$AENEAS_REF/aeneas"

mkdir -p "$CACHE_DIR"

# ── Toolchain prerequisites ──────────────────────────────────────────────
if ! command -v opam >/dev/null 2>&1; then
  echo "::group::Install opam"
  if [[ "$RUNNER_OS" == "Linux" ]]; then
    sudo apt-get update -qq
    sudo apt-get install -qq -y opam
  elif [[ "$RUNNER_OS" == "macOS" ]]; then
    brew install opam
  else
    echo "::error::Unsupported runner OS: $RUNNER_OS" >&2
    exit 1
  fi
  opam init --bare --auto-setup --disable-sandboxing -y
  eval "$(opam env)"
  echo "::endgroup::"
fi

# Source opam env for the rest of the script.
eval "$(opam env)" 2>/dev/null || true

# Ensure elan / Lean is on PATH — Aeneas links against Lean stdlib at translate time.
if ! command -v lean >/dev/null 2>&1; then
  echo "::group::Install elan + Lean"
  curl -sSf https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh \
    | sh -s -- -y --no-modify-path
  echo "$HOME/.elan/bin" >> "$GITHUB_PATH"
  export PATH="$HOME/.elan/bin:$PATH"
  echo "::endgroup::"
fi

# ── Charon ───────────────────────────────────────────────────────────────
if [ -x "$CHARON_BIN" ]; then
  echo "Charon $CHARON_REF — cache hit"
else
  echo "::group::Build Charon at $CHARON_REF"
  CHARON_DIR="$CACHE_DIR/charon-$CHARON_REF"
  rm -rf "$CHARON_DIR"
  git clone --quiet https://github.com/AeneasVerif/charon.git "$CHARON_DIR"
  ( cd "$CHARON_DIR" && git checkout --quiet "$CHARON_REF" && make build-dev-rustc -j )
  echo "::endgroup::"
fi
echo "$(dirname "$CHARON_BIN")" >> "$GITHUB_PATH"

# ── Aeneas ───────────────────────────────────────────────────────────────
if [ -x "$AENEAS_BIN" ]; then
  echo "Aeneas $AENEAS_REF — cache hit"
else
  echo "::group::Build Aeneas at $AENEAS_REF"
  AENEAS_DIR="$CACHE_DIR/aeneas-$AENEAS_REF"
  rm -rf "$AENEAS_DIR"
  git clone --quiet https://github.com/AeneasVerif/aeneas.git "$AENEAS_DIR"
  ( cd "$AENEAS_DIR" && git checkout --quiet "$AENEAS_REF" && make -j )
  echo "::endgroup::"
fi
echo "$(dirname "$AENEAS_BIN")" >> "$GITHUB_PATH"

echo "✓ Charon + Aeneas installed (refs: $CHARON_REF / $AENEAS_REF)"
