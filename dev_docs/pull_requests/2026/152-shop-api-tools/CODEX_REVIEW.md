# PR #152 — Shop API tools

Reviewer: Codex · Author: @timujinne · Reviewed: 2026-10-27
Local merge: `a213233` · Status: reviewed, fix applied.

## BUG - MEDIUM — a partially successful creation never refreshes subscribers

`CreateProducts.finish/4` deliberately leaves a created item in place when its
attribute write fails and returns an error row carrying the item's id and
`context.created: true`. `execute/3` collected only rows whose action was
`created`, so that item was excluded from the sole batch notification. Per-row
notifications were already suppressed. An open admin list or embedded browser
could therefore keep showing the old contents indefinitely.

Fixed the collected ids to include every persisted create, including partial
success. Skips and validation failures carry no id. Extended the existing
set-deleted-between-insert-and-attribute-write regression to verify the bulk
notification and catalogue roll-up, and the absence of a per-item event. It
failed before the fix.

Also reviewed the nine handlers, reference resolution and catalogue boundaries,
confirmation gate declarations and preview fingerprints, translation ownership,
external-id constraints/restores, price-field filtering, and batched item writes.
The previously recorded process-dictionary and ambiguous-SKU tradeoffs remain.
No additional API route or permission change is introduced.

## Validation

The 385-test initial focused suite includes the API tests. Final full-suite
and precommit results are recorded in `FOLLOW_UP.md`.

## Final validation — 2026-10-27

- `mix test`: 2 doctests, 4,360 tests, 0 failures; 10 checks excluded because
  the installed core lacks the newer schema-chain/manifest and file-reference
  test helpers. Database-backed tests ran.
- `mix precommit`: passed (warnings-as-errors compilation, lock/Hex checks,
  formatting, strict Credo and Dialyzer with the existing ignore configuration).
- `git diff --check`: passed.
