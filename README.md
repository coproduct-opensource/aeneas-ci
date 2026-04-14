# aeneas-ci

A reusable GitHub Action that keeps your committed Lean tree in sync with
the Rust source it was generated from, using [Charon] + [Aeneas].

[Charon]: https://github.com/AeneasVerif/charon
[Aeneas]: https://github.com/AeneasVerif/aeneas

## The pattern

Aeneas is a stateless transducer: `LLBC → Lean source`. It does not cache,
and it does not check whether its output has drifted from your committed
files. The canonical idiom (from Aeneas's own internal tests, where it is
spelled `REGEN_LLBC=1 make test-…`) is:

1. **Commit** the Aeneas-generated Lean tree to git as a build artifact-
   that-is-also-source-of-truth.
2. **Regenerate** in CI on every PR that touches the Rust source.
3. **`git diff --exit-code`** the regenerated tree against the committed
   tree; fail the PR on drift, with regen instructions in the PR comment.

This action packages that pattern. Drop it into your workflow, point it at
your Rust source dir and committed Lean output dir, and silent drift becomes
a build failure with clear remediation.

## Usage

```yaml
# .github/workflows/aeneas-freshness.yml
name: Aeneas Freshness

on:
  pull_request:
    paths:
      - 'crates/my-verified-core/src/**'
      - 'crates/my-verified-core/Cargo.toml'
      - 'Cargo.lock'

jobs:
  freshness:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v6
      - uses: coproduct-opensource/aeneas-ci@v1
        with:
          rust-source-dir: crates/my-verified-core
          lean-output-dir: lean/generated
          charon-version: <pinned commit SHA>
          aeneas-version: <pinned commit SHA>
```

That's it. PRs that drift now fail with a job summary like:

> ## Aeneas freshness drift detected
>
> The Lean tree at `lean/generated` is out of sync with the Rust source
> at `crates/my-verified-core`.
>
> **To fix locally:**
>
> ```bash
> cd crates/my-verified-core
> charon cargo --preset aeneas
> aeneas -backend lean *.llbc -split-files -dest $WORKSPACE/lean/generated
> git add lean/generated && git commit
> ```

## Inputs

| Input                | Required | Default            | Notes |
|----------------------|----------|--------------------|-------|
| `rust-source-dir`    | yes      | —                  | Crate root containing `Cargo.toml`. |
| `lean-output-dir`    | yes      | —                  | Where Aeneas writes (`-dest`). |
| `charon-version`     | yes      | —                  | Pinned commit SHA / tag. **Do not omit** — Charon's IR shape changes between versions. |
| `aeneas-version`     | yes      | —                  | Same. Must be a Charon-compatible pair. |
| `fail-on-drift`      | no       | `'true'`           | Set `'false'` for advisory runs. |
| `charon-extra-args`  | no       | `'--preset aeneas'`| Appended to `charon cargo`. |
| `aeneas-extra-args`  | no       | `'-split-files'`   | Appended to `aeneas -backend lean`. |

## Outputs

| Output           | Value |
|------------------|-------|
| `drift-detected` | `'true'` if regenerated tree differs from committed; `'false'` otherwise. Useful with `fail-on-drift: 'false'` for soft-warn workflows. |

## Why this exists

Charon and Aeneas are pure compilers, not stateful build tools. They push
caching responsibility onto the consumer's CI by design. Every downstream
project either:

- (a) runs Aeneas on every PR even when the Rust source hasn't changed
  (slow, wasteful), or
- (b) skips the freshness check entirely (silent drift between Rust
  semantics and Lean refinement targets), or
- (c) hand-rolls a bespoke workflow (boilerplate, easy to get wrong).

This action picks (d): a one-line `uses:` that runs only on Rust changes
(via path filters in your workflow), invokes the canonical pin/regen/diff
pipeline, and surfaces drift with copy-paste fix instructions.

## Three independent caches recommended

The action handles the freshness check. For the rest of the build, layer
three independent caches in your consumer workflow:

1. **Cargo / rustc** — `Swatinem/rust-cache@v2`, keyed on `Cargo.lock`.
2. **LLBC artifact** — `actions/cache`, keyed on `hashFiles('crates/*/src/**', 'Cargo.lock')` + `charon-version`.
3. **Lake / Mathlib** — keyed on `lean-toolchain` + `lakefile.lean` + `lake-manifest.json`, plus `lake exe cache get` for prebuilt mathlib oleans.

Don't merge these into one key — any Rust change would bust the Lake cache,
defeating `lake exe cache get`.

## Related anti-patterns

- **Don't commit `.llbc`** — binary, version-coupled to Charon, reproducible.
  Cache it, gitignore it.
- **Don't enable `precompileModules`** on libraries that import mathlib
  ([leanprover/lean4#9420](https://github.com/leanprover/lean4/issues/9420)).
- **Don't import generated Lean modules directly** from kernel proofs —
  go through a stable barrel module so a single regenerated def doesn't
  cascade into your hand-written proofs.

## Examples

- `examples/minimal/` — single-function `factorial` crate, no Mathlib.
  Runs in CI on every push to validate the action end-to-end.

## License

MIT. See [LICENSE](LICENSE).

## Acknowledgements

Pattern adapted from [AeneasVerif/aeneas]'s own `REGEN_LLBC=1` test idiom.
This action exists to bring it to downstream consumers without requiring
each project to reinvent the workflow.
