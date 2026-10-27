# PR #149 — Import encoding step

Reviewer: Codex · Author: @mdon · Reviewed: 2026-10-27
Local merge: `0e08787` · Status: reviewed, fix applied.

## BUG - MEDIUM — damaged BOM-marked files can be reinterpreted as a code page

`needs_code_page?/1` treated every refused, NUL-free binary as legacy text,
including a UTF-8 BOM followed by invalid UTF-8 and truncated UTF-16 without
any NUL bytes. The wizard consequently offered a code-page choice, and
`to_utf8/2` could import the BOM and damaged content as unrelated characters.
That contradicts the rule that a BOM names the encoding.

Fixed by excluding all three supported BOMs from code-page eligibility,
regardless of whether decoding succeeds. The regression covers damaged UTF-8
and both UTF-16 byte orders against every offered code page; it failed before
the fix. Ordinary legacy text still follows the confirmation step.

Also checked parser option propagation, sheet re-parsing, encoding-state reset,
undefined-byte refusal, and the CSV/PRO100 source entry points. The existing
heuristic scoring and repeated validation remain unchanged.

## Validation

Initial focused suite: 385 tests, no failures. New regressions: three failures
before the fixes, all passing afterwards. Final full-suite and gate results
are recorded in this directory's follow-up.

## Final validation — 2026-10-27

- `mix test`: 2 doctests, 4,360 tests, 0 failures; 10 checks excluded because
  the installed core lacks the newer schema-chain/manifest and file-reference
  test helpers. Database-backed tests ran.
- `mix precommit`: passed (warnings-as-errors compilation, lock/Hex checks,
  formatting, strict Credo and Dialyzer with the existing ignore configuration).
- `git diff --check`: passed.
