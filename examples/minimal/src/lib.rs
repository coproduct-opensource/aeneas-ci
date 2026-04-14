//! Minimal Aeneas-translatable example: the factorial function.
//!
//! This crate exists to exercise the `aeneas-ci` freshness-check workflow
//! end-to-end. The Lean output lives at `examples/minimal/lean-out/` and is
//! committed to git; the workflow regenerates and `git diff`s on every PR.

#![no_std]

/// Compute n! recursively. Total for n ≥ 0; Aeneas translates this into
/// a structurally-recursive Lean function with a `Nat → Nat` signature.
pub fn factorial(n: u64) -> u64 {
    if n == 0 {
        1
    } else {
        n * factorial(n - 1)
    }
}
