# Follow-up Items for PR #4

Triaged against `main` on 2026-04-26. PR #4 was the v0.2.0 release that
addressed most of PR #1's findings inline. The CLAUDE_REVIEW for PR #4
explicitly noted findings #1, #2, #4, #5, #6 as fixed during the PR
itself and only carried two open items forward.

## Fixed (in-PR — already noted in the review)

- ~~**#1** Missing Gettext on "Markup" display text~~ — fixed in-PR.
- ~~**#2** Missing Gettext on markup helper text~~ — fixed in-PR.
- ~~**#4** Search overlay hides unrelated tabs~~ — fixed in-PR.
- ~~**#5** No upper bound on `markup_percentage`~~ — fixed in-PR
  (`less_than_or_equal_to: 1000`).
- ~~**#6** Pattern match risk on `confirm_delete` assigns~~ — fixed
  in-PR via `confirm_delete!/1` helper. Subsequently hardened by PR #10
  which replaced the raising helper with `unexpected_confirm_event/2`
  (safe case-match + flash) — closing PR #7's review bug #3 of the same
  family.

## Fixed (carried forward to other PRs and resolved)

- ~~**#7** `next_category_position` race condition persists~~ — same
  finding as PR #1 #4. Now resolved for the two transactional write
  paths (`move_category_to_catalogue/3`, `move_category_under/3`) by
  PRs #7/#10/#11. See `1-initial-catalogue-module/FOLLOW_UP.md` for the
  full carryover trail. Phase 2 sweep on this branch documents the
  remaining "must call inside a transaction" requirement on the public
  function.

## Skipped (with rationale)

- **#3** `list_uncategorized_items` is now truly global — design
  decision flagged by the reviewer rather than a defect. The function
  honestly returns ALL orphaned items globally; the LV calls it from
  the catalogue detail page knowing this. Renaming it back would
  re-introduce the misleading-name problem the rename solved. The UX
  question (should the detail page show only items "near" this
  catalogue?) is a product decision, not a code defect. No change.

## Files touched

None in this batch — all actionable items resolved before this sweep
started.

## Verification

- All in-PR fixes re-verified against current `lib/`.
- Cross-checked `confirm_delete!` references — only `unexpected_confirm_event`
  remains (PR #10).

## Open

None.
