# PR #155 — Neutral host wording

Reviewer: Codex · Author: @timujinne · Reviewed: 2026-10-27
Local merge: `776309b` · Status: reviewed, no additional defect found.

Compared the documentation/comments and fixture substitutions. Production
changes are comments; fixture names and corresponding assertions move together.
The PRO100 group separator and foreign-group cases retain their inputs' relevant
shape, and the renamed tree variables preserve their references. No code change
was warranted. Validation includes the full suite and precommit gate.

## Final validation — 2026-10-27

- `mix test`: 2 doctests, 4,360 tests, 0 failures; 10 checks excluded because
  the installed core lacks the newer schema-chain/manifest and file-reference
  test helpers. Database-backed tests ran.
- `mix precommit`: passed (warnings-as-errors compilation, lock/Hex checks,
  formatting, strict Credo and Dialyzer with the existing ignore configuration).
- `git diff --check`: passed.
