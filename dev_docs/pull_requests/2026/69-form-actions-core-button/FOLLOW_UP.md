# Follow-up: PR #69 — Form actions on core button

Triaged 2026-08-19 (quality-sweep Phase 1). Source review: `CLAUDE_REVIEW.md`.

## Fixed (pre-existing)

- ~~BUG MEDIUM: "Delete Forever" emitted `btn-primary` and `btn-error` together~~ — both forms use `variant="error"` + `class="btn-outline shrink-0"` (`catalogue_form_live.ex:654–657`, `category_form_live.ex:749–752`); regression tests `test/web/form_lives_test.exs:413–434` (`refute classes =~ "btn-primary"`).
- ~~NITPICK: `class="btn-outline"` on Save looked like a mistake~~ — explanatory comments in both form LVs.

## Skipped (with rationale)

- N/A: the PR *description's* remaining-site count — about the GitHub PR body, not the tree.
- observation: hand-written `btn` class sites across `lib/` (106 at review time, 99 at this triage) — explicitly recorded by the review as a later migration pass, not a defect. Unchanged scope.

## Open

None.
