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
# Charon's Makefile puts the built binary in $CHARON_DIR/bin/charon.
# Aeneas's Makefile puts the built binary in $AENEAS_DIR/bin/aeneas.
# We cache-detect by checking the `bin/<tool>` file.
CHARON_BIN="$CACHE_DIR/charon-$CHARON_REF/bin/charon"
AENEAS_BIN="$CACHE_DIR/aeneas-$AENEAS_REF/bin/aeneas"

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

# Source opam env for the rest of the script. If no default switch exists
# yet (fresh opam init --bare), create one with a pinned compiler. Upstream
# Aeneas + Charon moved to OCaml 5 (5.3.0 is the current dev target per
# Aeneas's opam variants metadata); 4.14.x no longer builds against current
# Charon main because its ppx packages require OCaml 5.
eval "$(opam env)" 2>/dev/null || true
if ! opam switch show >/dev/null 2>&1; then
  echo "::group::Create opam switch (OCaml 5.3.0)"
  opam switch create ci 5.3.0 -y
  eval "$(opam env --switch=ci)"
  echo "::endgroup::"
fi

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
  (
    cd "$CHARON_DIR"
    git checkout --quiet "$CHARON_REF"
    # Install Charon's OCaml deps (dune, menhir, visitors, ppx_deriving,
    # zarith, etc.) from the charon.opam manifest. Without this
    # `make build-charon-ml` fails with "dune: command not found" (exit 127).
    opam install --deps-only -y . ./charon-ml
    # `charon-ml/Makefile`'s `build-dev` target runs `dune build @doc`,
    # which requires `odoc`. odoc is NOT in charon-ml.opam's deps (docs
    # are an extra), so install it explicitly. Without this, the build
    # fails with "Program odoc not found in the tree or in PATH" (exit 2).
    opam install -y odoc
    # Build the Rust driver and the OCaml side explicitly; the upstream
    # Makefile recommends this pair for CI. `build-dev` still aggregates
    # both but the explicit form is more future-proof against Makefile
    # reorganization. Debug build skips cargo fmt (which needs rustfmt on
    # the pinned nightly toolchain, not always available); binary lands in
    # bin/charon identically to release. See
    # https://github.com/AeneasVerif/charon/blob/main/Makefile
    make build-dev-charon-rust build-dev-charon-ml -j
  )
  echo "::endgroup::"
fi
dirname "$CHARON_BIN" >> "$GITHUB_PATH"

# ── Aeneas ───────────────────────────────────────────────────────────────
if [ -x "$AENEAS_BIN" ]; then
  echo "Aeneas $AENEAS_REF — cache hit"
else
  echo "::group::Build Aeneas at $AENEAS_REF"
  AENEAS_DIR="$CACHE_DIR/aeneas-$AENEAS_REF"
  rm -rf "$AENEAS_DIR"
  git clone --quiet https://github.com/AeneasVerif/aeneas.git "$AENEAS_DIR"
  (
    cd "$AENEAS_DIR"
    git checkout --quiet "$AENEAS_REF"
    # Aeneas's Makefile gates `make check-charon` on `./charon` existing
    # as a clone (or symlink) inside the Aeneas tree. Without it the
    # build fails with:
    #   Error: `charon` not found. Please clone the charon repository
    #   into `./charon` at the commit specified in `./charon-pin`, or
    #   make a symlink to an existing clone of charon.
    # Symlink the cached Charon clone we already built above.
    ln -snf "$CACHE_DIR/charon-$CHARON_REF" ./charon
    # Install Aeneas's OCaml deps from its opam manifest.
    opam install --deps-only -y . || true
    # Default target = build = build-dev = build-bin + build-lib +
    # build-bin-dir, which produces bin/aeneas. Requires Charon on PATH
    # (set above).
    #
    # DO NOT export IN_CI=true here. Aeneas's Makefile gates `build-dev`
    # to be a no-op (`@true`) when IN_CI is set, on the assumption that
    # the build already happened in an earlier CI step. Setting it would
    # skip the build entirely and leave bin/aeneas missing.
    make -j
  )
  echo "::endgroup::"
fi
dirname "$AENEAS_BIN" >> "$GITHUB_PATH"

echo "✓ Charon + Aeneas installed (refs: $CHARON_REF / $AENEAS_REF)"
