# PR #157 — Settings permission and AI event gate

Reviewer: Codex · Author: @mdon · Reviewed: 2026-10-27
Local merge: `c266b2f` · Status: reviewed, no additional defect found.

Checked the settings permission declaration/tab, mount refusal and all six write
events against `Scope.can?/2`'s base-permission and live-enablement checks.
The backfill uses raising lookups, records completion only after successful
grants, retries failed passes, and respects later revocation.

Compared the AI gate's six event names with the actual embed handlers and
verified gate-before-embed hook ordering on all four forms. Existing tests drive
mid-session revocation through real LiveViews, including each AI form. The
initial focused suite passed all 385 tests, including settings/backfill and AI
revocation cases. No implementation change was warranted; final validation also
includes the full suite and precommit.

## Final validation — 2026-10-27

- `mix test`: 2 doctests, 4,360 tests, 0 failures; 10 checks excluded because
  the installed core lacks the newer schema-chain/manifest and file-reference
  test helpers. Database-backed tests ran.
- `mix precommit`: passed (warnings-as-errors compilation, lock/Hex checks,
  formatting, strict Credo and Dialyzer with the existing ignore configuration).
- `git diff --check`: passed.
