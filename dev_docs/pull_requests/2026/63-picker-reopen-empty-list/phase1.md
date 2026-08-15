# PR #63 Phase 1 Review — phoenix_kit_catalogue
**Title:** Fix: reopening the picker for an already-loaded item showed an empty list
**Author:** Tymofii Shapovalov (timujinne)
**Date reviewed:** 2026-08-15
**Verdict:** APPROVE WITH NOTES

---

## Summary

Production bug in a furniture-ERP consumer app: clicking an already-selected item reopened the picker with "No items found" instead of a replacement list. First-open and live-selection (no page reload) were unaffected.

**Root cause** (well-diagnosed): `handle_event("open", …)` only re-ran the search when `options == [] AND query == ""`. But `update/2` on mount mirrors the selected item's name into `:query`. So a picker mounted with `selected_item` (i.e. after page reload) enters with a non-empty query and empty options — the search condition never fired, and the dropdown opened empty.

**Fix**: Drop the `query == ""` requirement from the guard — `options == []` alone is the correct trigger. The comment added is accurate and helpful.

**Bonus fix**: A latent `BadBooleanError` was exposed by making that code path reachable. The HEEx `:if` guard used `price && price != ""` as the left operand of `or`. In Elixir, `&&` returns the value itself (not a boolean), so for `price == nil` this yields `nil`, and `nil or unit != ""` raises `BadBooleanError` (since `or` requires strict booleans). Fixed correctly to `price != nil and price != ""`.

Both changes are minimal, targeted, and don't touch unrelated code.

---

## Findings

### Blockers

None.

### Non-blockers

1. **No version bump** — `mix.exs` stays at `0.15.0`. This is a user-visible bug fix and warrants `0.15.1` before publishing to Hex. Not a PR blocker per se, but must be done before the release step.

2. **Test assertion could be stronger** — The regression test (`item_picker_reopen_test.exs`) asserts the listbox is present and "No items found" is absent, but only asserts `"Preselected Item"` is in the HTML. That name also appears in the `<input value=...>` field, so the assertion doesn't prove the dropdown list contains a *replacement* item. Asserting `"Sibling Item"` (which the fixture creates but never checks) would be a tighter proof. The external reviewer (noted in PR body) flagged the same point. Test still fails on old code, so coverage goal is met — just weaker than it could be.

3. **Zero-results reopen causes unnecessary re-fetch** — With the new condition, focusing after a zero-results search reruns the query. Not wrong (user likely wants a retry), but it's a mild behavioral change worth knowing. Low severity, no user-facing downside.

### Nitpicks

- `async: false` in `ItemPickerReopenTest` — probably required for `live_isolated` fixture interaction, but worth a comment or confirmation that it can't be `async: true`.
- The `@moduledoc` in the test module uses an `L027` code; if the team uses these codes consistently, fine — if not, it's noise.
- Inner `:if={price && price != ""}` on the sibling `<div>` inside the fixed block was not changed. `price && price != ""` is still there on line 609 (`<div :if={price && price != ""}`). This is fine inside `:if` (truthiness check, not strict boolean), but stylistically inconsistent with the just-fixed guard above it.

---

## Stats

| Metric | Value |
|---|---|
| Files changed | 2 |
| Additions | 65 |
| Deletions | 2 |
| Tests added | 1 new file, 1 test |
| Migrations | None |
| Version bump | ❌ None (0.15.0 unchanged) |
| Dependency changes | None |

---

## Recommendation

Approve and merge. Request version bump to `0.15.1` before the Hex release step (can be done post-merge in the release PR or as a follow-up commit). The stronger sibling-item assertion is a good-to-have, not a gate.
