# PR #63 follow-up

Triage of `GROK_REVIEW.md` (2026-08-15), resolved 2026-08-16 on Max's
"fix those problems and nitpicks" go-ahead. Shipped inside the #67 PR
branch.

## Fixed (Batch 1 — 2026-08-16)

- ~~1. IMPROVEMENT-MEDIUM — reopen after reload is a name search, not a
  replacement list~~ — implemented the review's recommended follow-up:
  `handle_event("open", …)` now BROWSES (searches the empty query, the
  first page) when options are empty AND the query equals the selected
  item's mirrored display name, leaving the input text untouched.
  `run_search/2` gained a `query_override` arg so the `:query` assign
  stays the item's name. `item_picker.ex`.
- ~~2. IMPROVEMENT-LOW — the name-search assertion is weaker than it
  looks~~ — `item_picker_reopen_test.exs` now asserts the SIBLING item
  appears (valid only because of fix 1 — it failed on the previous
  code, exactly as the review predicted), plus an option-level
  `[id^='host-picker-option-']` pin so a filled input with an empty
  list can't satisfy the test.
- ~~3. IMPROVEMENT-LOW — the unmasked `BadBooleanError` has no test~~ —
  added a render-shape pin: `open: true`, `format_price: fn _ -> nil
  end`, `show_unit: false` renders the option name and omits the price
  column. `item_picker_test.exs`.
- ~~4. NITPICK — inner price `:if` still uses `&&`~~ — now
  `price != nil and price != ""`, matching the outer predicate's
  spelling. `item_picker.ex`.
- ~~5. NITPICK — zero-result refetch on re-focus~~ — kept as behavior
  (the review itself leans "a user who got nothing may even want the
  retry"); now documented as deliberate in the `open` handler comment.
- ~~6. NITPICK — `async: false` unexplained~~ — one-line comment added
  ("shares the Repo sandbox with the isolated host LV").

## Skipped (with rationale)

- Version bump to 0.15.1 + CHANGELOG bullet — releases are boss-only
  (workspace rule); upstream is past 0.15.x anyway.

## Files touched

| File | Change |
|------|--------|
| `lib/phoenix_kit_catalogue/web/components/item_picker.ex` | browse-on-reopen branch, `run_search/2` query override, `query_is_selection_name?/1`, `and` spelling, retry comment |
| `test/web/item_picker_reopen_test.exs` | sibling + option-level assertions, async comment |
| `test/web/item_picker_test.exs` | nil-price render pin |

## Verification

`mix precommit` clean; picker files 31 tests / 0 failures; full suite at
the documented 2-failure URL-state baseline.

## Open

None.
