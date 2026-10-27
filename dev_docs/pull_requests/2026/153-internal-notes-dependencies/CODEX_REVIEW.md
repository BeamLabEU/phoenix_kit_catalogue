# PR #153 — Internal categories, AI notes and dependencies

Reviewer: Codex · Author: @mdon · Reviewed: 2026-10-27
Local merge: `5004adc` · Status: reviewed, fix applied.

## BUG - HIGH — a dependency conflict discards unsaved item fields and location

The conflict branch called `refresh_after_edit/2`, which rebuilds a clean item
changeset and clears the staged location. The dependency draft survived, but a
typed name/description/AI note and an intended move vanished when another admin
saved the dependencies first. The next Save could succeed with those changes
silently lost, contrary to the branch's stated preservation contract.

Fixed the branch to load the fresh item as the base and rebuild its changeset
from the submitted parameters, retaining the other staged assigns. The refreshed
dependency base still makes a second Save an explicit replacement. Strengthened
the two-admin integration test: the rename and staged move survive refusal,
nothing is half-saved, and submitting the rendered form again applies both the
original field edits and move along with the retained dependency draft. The
field-preservation assertion failed before the fix.

Also checked the internal-category exclusion in search and the three embeds,
optional dependency details, replace-all validation and conflict semantics,
dependency import/export and duplication, and the V6 schema constraints. Existing
large-tree and per-reference import-query tradeoffs remain unchanged.

## Validation

The three new regressions failed before their fixes; the 100-test regression
suite passed afterwards. Final full-suite and precommit results are recorded
in `FOLLOW_UP.md`.

## Final validation — 2026-10-27

- `mix test`: 2 doctests, 4,360 tests, 0 failures; 10 checks excluded because
  the installed core lacks the newer schema-chain/manifest and file-reference
  test helpers. Database-backed tests ran.
- `mix precommit`: passed (warnings-as-errors compilation, lock/Hex checks,
  formatting, strict Credo and Dialyzer with the existing ignore configuration).
- `git diff --check`: passed.
