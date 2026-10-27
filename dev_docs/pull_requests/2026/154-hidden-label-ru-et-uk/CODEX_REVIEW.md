# PR #154 — Hidden-category labels

Reviewer: Codex · Author: @timujinne · Reviewed: 2026-10-27
Local merge: `8ef5c4d` · Status: reviewed, no additional defect found.

Compared the three translation changes with the pinned gettext expectations.
Only the displayed `Internal` label changes in Estonian, Russian and Ukrainian;
the English msgid, explanatory text, and category semantics are preserved.
No implementation change was warranted. Validation includes the full suite's
gettext coverage and precommit gate.

## Final validation — 2026-10-27

- `mix test`: 2 doctests, 4,360 tests, 0 failures; 10 checks excluded because
  the installed core lacks the newer schema-chain/manifest and file-reference
  test helpers. Database-backed tests ran.
- `mix precommit`: passed (warnings-as-errors compilation, lock/Hex checks,
  formatting, strict Credo and Dialyzer with the existing ignore configuration).
- `git diff --check`: passed.
