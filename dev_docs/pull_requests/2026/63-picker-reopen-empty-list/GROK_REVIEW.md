# Review — PR #63: Reopening the picker for an already-loaded item showed an empty list

**Author:** Tymofii Shapovalov (@timujinne)
**Reviewed:** 2026-08-15
**Status:** Merged as `e4543b8` (`b81e924` on `timujinne/fix/item-picker-reopen`)
**Verdict:** SHIP as a focused bugfix. Not unfinished work.

This is **not** the "Max, please continue" PR. That handover is
[#62](/dev_docs/pull_requests/2026/62-handover-notes) / root `HANDOVER.md`
(L028 product attributes designed-but-unbuilt, L029 forms draft). PR #63 is a
complete L027 production fix: two files, one root cause, one latent crash it
unmasked, one new integration test.

Reviewed against the Phoenix thinking skill. The change lives entirely in a
`LiveComponent` (`ItemPicker`); no `mount/3` query issue in production code
(the test host's `get_item/2` in `mount/3` is test-only). `run_search/1` stays
in the event path (`open` / `query_change`), which is the right place.

An earlier first-pass note sits in `phase1.md`. This review starts from the
merged code and from running the new test (pass) plus a sibling-item probe
(fail — see finding 1).

---

## What landed

`handle_event("open", …)` used to re-run search only when **both**
`options == []` **and** `query == ""`. `update/2` mirrors a newly assigned
`selected_item`'s display name into `:query` on every first mount (and on
every later UUID change). After a page reload the picker therefore comes up
with `query != ""` and `options == []`, the guard never fired, and focusing
the input opened the empty-query-mismatch empty state: **"No items found"**.

A live pick in the same process never hit this: `options` still held the
search that led to the selection.

**Fix:** drop the `query == ""` clause. Empty options alone re-run the
search. The new comment is accurate about *why* the query cannot participate
in the guard.

**Bonus:** rendering a result row used `(price && price != "") or unit != ""`.
`&&` returns the left value, so a `nil` price made the `or` see `nil` and
raise `BadBooleanError` (`or` is strict-boolean). Unreachable while options
stayed empty on reopen; reachable for any price-less item once this path
filled the list. Changed to `(price != nil and price != "") or unit != ""`.

`test/web/item_picker_reopen_test.exs` mounts a fresh isolated host with
`selected_item` set and no prior `query_change`, focuses the input, and
asserts the listbox is present and "No items found" is absent.

---

## Findings

### 1. IMPROVEMENT - MEDIUM — reopen after reload is a name search, not a replacement list

The PR body and the new comment promise a **replacement list** — "the same
non-empty replacement list a freshly-selected item shows". That is not what
the new branch does.

`run_search/1` always searches with the current `:query`. After a reload
that query is the selected item's display name, so the dropdown is
`Catalogue.search_items("Preselected Item", …)` — typically **one row, the
already-chosen item**.

Verified against the merged test: adding `assert html =~ "Sibling Item"`
fails. The rendered listbox contains only `host-picker-option-0` /
"Preselected Item". The `_sibling` fixture is created and never observed.

The live-selection path is still different: `select` does not refresh
`options`, so reopening after a pick shows whatever the user last searched
(often the empty-query first page of ten, or a typed prefix). After reload
they get a 1-item name match and must edit or clear the input to find a
replacement.

That is standard combobox behaviour and **strictly better than "No items
found"**. It is not the replacement list the write-up claims, and the unused
sibling is a tell that the test never checked it.

If the furniture-ERP flow is "click the already-chosen product to pick a
different one", a stronger follow-up is: on first `open` after a
mount-with-selection, search with `""` (or a dedicated "browse" query)
while leaving the input text as the item name. That is a product call, not
a crash.

Do **not** "strengthen" the existing test by asserting `"Sibling Item"`
without changing `run_search/1` — that assertion fails on this code.

### 2. IMPROVEMENT - LOW — the name-search assertion is weaker than it looks

`assert html =~ "Preselected Item"` is also true of the closed input
(`value="Preselected Item"`). The things that actually prove the bug is
gone are:

- `refute html =~ "No items found"`
- `assert html =~ ~s(id="host-picker-listbox")` (listbox only renders when
  `@open and @options != []`)

Those two are enough for the empty-list regression. A tighter pin would
assert a listbox **option** for the selected item, e.g. the option id or
`aria-selected="true"`, so a future change that leaves the input filled
but the list empty fails for the right reason.

The independent review Tim cited already flagged the selected-name
assertion. They suggested asserting the sibling instead — which, per
finding 1, would fail today.

### 3. IMPROVEMENT - LOW — the unmasked `BadBooleanError` has no test

The boolean fix is correct. Nothing pins it.

`item_picker_test.exs` render-shape cases all pass
`format_price: &constant_price/1` (`"€123"`), so they never hit a `nil`
price. The new integration test uses `fixture_item/1` with a default
`base_price`, so `default_format_price/1` returns a string and the old
`or` would not have crashed there either.

A cheap pin: `render_component` with `open: true`, an option whose
`format_price` returns `nil` (or a smart item with no `base_price`), and
`show_unit: false`. Before the guard change that raises; after, it
renders the name and omits the price column.

### 4. NITPICK — inner price `:if` still uses `&&`

```heex
<div :if={(price != nil and price != "") or unit != ""}>
  <div :if={price && price != ""} class="text-sm font-medium">
```

The inner `:if` is truthiness, not `or`, so it does not crash. Same
predicate, two spellings. Harmless.

### 5. NITPICK — zero-result refetch on re-focus

After a typed search that returned `[]`, the next focus runs the same
query again. Tim and the earlier pass already noted this. Extra request,
not a wrong result; a user who got nothing may even want the retry.

### 6. NITPICK — `async: false` unexplained

Matches `item_picker_card_test.exs` / `LiveCase` + `live_isolated` + DB
fixtures. Fine. A one-line "shares the Repo sandbox with the isolated
host" would save the next reader a look.

---

## What this PR is not

| Ticket | Where it lives | Status |
|---|---|---|
| L027 (this PR) | `item_picker.ex` + `item_picker_reopen_test.exs` | Done, merged |
| L028 product attributes / characteristics | `HANDOVER.md` §2 | Designed with the PO, **not started** |
| L029 PhoenixKit form-component pass | `HANDOVER.md` §2 | Draft only |
| Spectator-host stale card, locale dual-source, L026 indent | `HANDOVER.md` §3 | P2, carried |
| 3 pre-existing red tests on `main` (URL `?q=` / empty `?category=`, DnD reorder) | `HANDOVER.md` §3, also PR #61 review | Unrelated, still red |

No version bump (`mix.exs` stays `0.15.0`). Correct for this PR; the
user-visible picker fix wants `0.15.1` before the next Hex publish, with a
CHANGELOG `### Fixed` bullet. No gettext, no migrations, no new host
contract.

---

## Gate

- New test file, 1 test: **pass** (`mix test test/web/item_picker_reopen_test.exs`).
- Sibling-item probe against the same setup: **fail** (list is the selected
  name only). Reverted; tree left as merged.
- `mix precommit` / full suite not re-run here. Tim reported format +
  `credo --strict` clean, and the same 3 pre-existing failures as #61/#62.
  No reason to expect this two-hunk change to move those.

---

## Recommendation

Leave the merge. Optional follow-ups, none blocking:

1. Decide whether post-reload focus should browse (`query` empty for
   search, input still showing the name) or keep today's name-search.
   If browse: change `open` to search `""` when options are empty **and**
   the query equals the selected item's display name; then the sibling
   assertion becomes the right pin.
2. Pin the `nil`-price row so the `BadBooleanError` cannot come back.
3. Bump to `0.15.1` when this ships to Hex.

If the next person is picking up Tim's unfinished catalogue work, start
from `HANDOVER.md` L028, not from this PR.
