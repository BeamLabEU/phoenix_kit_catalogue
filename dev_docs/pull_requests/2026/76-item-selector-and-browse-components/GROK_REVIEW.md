# Review — PR #76: Item selector modal and embeddable browse components

**Author:** Max Don (@mdon)
**Reviewed:** 2026-08-22
**Status:** Merged as `c6fbd1f` (`d1d3c7d` on `feat/item-selector-and-browse-components`)
**Verdict:** SHIP the architecture. Several real post-merge bugs fixed on
main before the 0.18.0 Hex publish.

Reviewed against phoenix-thinking, ecto-thinking, and elixir-thinking.
LiveComponents query on first `update/2` (the LC equivalent of mount; they
have no `handle_params`), gated by `initialized` so a parent re-render does
not clobber live selection. `BrowseState` is a plain struct + functions —
no process without a runtime reason.

The PR's own second-pass review already closed `:only` missing from
hydration, exponent quantities, string-keyed scope silently widening,
crafted payloads crashing the picker LV, and unbounded search strings.
This review is the leftover: two lists that must stay in sync with
`Search.search_items/2` had drifted, and a documented morphdom workaround
was never actually implemented.

---

## What landed

One stack, three layers:

1. **`Catalogue.BrowseState`** — pure reducer (scope / search / category /
   offset paging / generation counter). No process, no queries.
2. **`Web.Components.Browse`** — function components (`item_card`,
   `item_grid`, `category_chips`, `qty_stepper`, `grid_skeleton`) plus
   `present_items/2`.
3. **`ItemSelectorModal` / `CatalogueBrowse`** — LiveComponents. Picker
   reports `{:items_selected, %{picks: …}}` / `{:item_selector_closed, _}`;
   browse reports `{:catalogue_browse, %{event: :item_clicked, …}}`.

Host mounts the picker with `:if` so unmount-on-close gives clean reopen.
Quantities are Decimal; confirm payload is a display snapshot (re-price
server-side).

---

## Findings

### 1. BUG - HIGH — `:statuses` was documented as `search_items/2` vocabulary and then ignored *(fixed)*

`BrowseState.query_opts/1` forwarded `:statuses`. `Search.search_items/2`
never read it. `CatalogueBrowse`'s own example is
`scope={%{catalogue_uuids: […], statuses: ["active"]}}`. Inactive and
discontinued items still appeared in the grid, and `card_click` accepted
them because they were rendered. Hydration `in_scope?/2` *did* honour
statuses, so the two clamps disagreed.

**Fix:** `Search` now filters `i.status in ^statuses` (`nil`/`[]` keep the
historical "all non-deleted" default). Atoms stringify. Soft-deleted rows
stay excluded even if `"deleted"` is listed.

### 2. BUG - HIGH — `in_scope?/2` crashed on `category_uuid: nil` *(fixed)*

`allowed?(list, value)` ended in `to_string(value) in …`. `to_string(nil)`
raises `Protocol.UndefinedError`. An uncategorized preselect against a
`category_uuids` (or `:categorized_only`) scope took the whole host
LiveView down — the exact "crafted payload must not crash the LV" rule
the PR already applied to events, missed on hydration.

**Fix:** `allowed?(_list, nil)` is `false`. Restriction lists never match a
missing value.

### 3. BUG - HIGH — `:categorized_only` was missing from hydration *(fixed)*

The PR's own review closed `:uncategorized_only`. `:only` has two values
in `Search`. `only_ok?(_other, _) -> true` blessed an uncategorized
preselect under `:categorized_only` as confirmable.

**Fix:** explicit `:categorized_only` clause. Test pins both directions.

### 4. BUG - HIGH — hydration category membership ignored descendant expansion *(fixed)*

`Search.search_items/2` defaults `include_descendants: true`, so a parent
category scope returns items in child categories and `card_click` can
select them. `in_scope?/2` tested exact `category_uuid` membership, so the
same item arriving as a preselect was flagged unavailable and dropped from
confirm. Editing an order that already contains a nested-category line
would silently lose it.

**Fix:** expand once per hydrate via `Tree.subtree_uuids_for/1` (the same
expander Search uses), skipped when the host passed
`include_descendants: false`. UUID comparison normalises Tree's 16-byte
binaries against textual ids.

### 5. BUG - HIGH — cards showed `base_price`, not the selling price *(fixed)*

`present_items/2` copied `item.base_price`. The existing `ItemPicker`
defaults to `Catalogue.item_pricing/1`'s `final_price`. A catalogue with
10% markup displayed 100.00 on the card and in the confirm snapshot
instead of 110.00. Hosts are told to re-price, but the display-only
snapshot is what they render in the summary.

**Fix:** `%Item{}` goes through `item_pricing/1`. Map doubles in
render-shape tests still fall back to `base_price` so they stay DB-free.

### 6. BUG - HIGH — `default_value` was used as the starting pick quantity *(fixed)*

The design called this "the paint case" (`2.5 L`). `Item.default_value` /
`default_unit` are the **smart-catalogue fee fallback** (`percent` /
`flat`), consumed by `CatalogueRule.effective/2`. A smart item with
`default_value: 5` ("5% across everything") would open the stepper at
qty 5. There is no starting-quantity column.

**Fix:** starting qty is always 1. Hosts that need a non-1 opening qty
pass it in `selected`. A dedicated starting-qty field remains deferred.

### 7. BUG - MEDIUM — the morphdom qty-revision was documented, never implemented *(fixed)*

Moduledoc and design note: invalid commits bump a per-row revision in the
input id because morphdom will not clear typed garbage when the `value`
attr is unchanged. `drafts` was initialised to `%{}`, deleted on every
`put_qty` / error path, and never incremented. `qty_rev/2` always
returned 0.

**Fix:** every `qty_commit` increments `drafts[uuid]`. `put_qty` no longer
wipes it. Invalid `"abc"` after a select now changes the stepper id from
`-r0` to `-r1`.

### 8. BUG - MEDIUM — category chips preloaded every item in the catalogue *(fixed)*

`chip_categories/1` called `list_categories_for_catalogue/1`, whose
contract is "preloads items (non-deleted only)". Opening the picker on a
large catalogue loaded every item just to render chip names.

**Fix:** `list_categories_metadata_for_catalogue/1` (exists specifically
for this).

### 9. BUG - MEDIUM — preselect hydration was N+1 `get_item/1` and included deleted rows *(fixed)*

One `Catalogue.get_item/1` per preselected uuid, and `get_item/1` does not
exclude `status: "deleted"`. Search never returns deleted items, so a
deleted preselect could confirm as a pick when the host did not pass
`:statuses`.

**Fix:** `Catalogue.list_items_by_uuids/2` — one query, already drops
soft-deleted rows, built for snapshot rehydration.

### 10. BUG - MEDIUM — `CatalogueBrowse` had no event catch-all and did not validate scope *(fixed)*

The picker grew a catch-all after the implementation review so a crafted
payload degrades to a no-op. `CatalogueBrowse` did not: missing keys on
`browse_search` / `card_click` were a `FunctionClauseError` that killed
the host LV. It also skipped `validate_scope!`, so a string-keyed scope
silently widened — the failure mode the picker existed to prevent.

**Fix:** scope validation lives in `BrowseState.init/1` (both surfaces,
and any host composing the reducer). `CatalogueBrowse` has the same
catch-all. Non-binary `{:search, _}` / `{:set_category, _}` are no-ops on
the reducer.

### 11. BUG - LOW — Confirm stayed enabled when every pick was unavailable *(fixed)*

An out-of-scope-only preselection made the tray say "1 item" (correct —
the host's data is shown) but left Confirm clickable, emitting an empty
`picks` list. Disabled unless at least one entry is `available`.

### 12. IMPROVEMENT - MEDIUM — LiveComponents called `Catalogue.Search` directly *(fixed)*

AGENTS.md: LiveViews and external consumers go through
`PhoenixKitCatalogue.Catalogue`; internal submodules are re-exported.
Both LCs now call `Catalogue.search_items/2` / `count_search_items/2`.
Hydration still uses `Tree.subtree_uuids_for/1` because that is the same
expander Search uses and there is no public `Catalogue` wrapper; noted
here so it is not "simplified" into a recursive query in the LV.

### 13. NITPICK — `include_descendants` was missing from the scope key list *(fixed)*

A host that needed literal (non-tree) category membership had no way to
say so without an unknown-key raise. The key is now in `@scope_keys` and
survives every fetch command.

### 14. NITPICK — chip names are the primary-language column, not `translated_name/2`

Client-facing chips ignore the viewer's locale. Not fixed in this pass —
chip rendering is a one-line change later and does not affect the
security boundary.

### 15. NITPICK — `chip_categories/1` is duplicated across the two LCs

Deliberate in the PR ("cheap the day a third surface appears"). Left.

---

## Verified as correct

- **Scope never widens.** Category commands outside `scope.category_uuids`
  are `:noop`. Fetch opts always re-derive from the immutable scope.
  Adversarial tests were written to fail when either clamp is removed.
- **Selection is closed over rendered (or hydrated) uuids.** A crafted
  `card_click` with a foreign uuid cannot enter the map.
- **Qty hostile input.** Decimal comma accepted; exponent forms rejected;
  min/max/precision re-clamped; ceiling at 1_000_000. Integer precision
  rounds.
- **Generations.** Stale `ingest/4` discarded whole. Unchanged search /
  category is a no-op. Offset-page duplicates de-duped by uuid.
- **`initialized` guard** on both LCs — parent re-render does not clobber
  live state. Only `:title` refreshes on the picker.
- **Immediate single mode** confirms on the tap itself with the *new*
  selection (socket rebound before `confirm_payload/1`).
- **Gettext.** New strings are in `default.pot` and en/et/ru; et/ru
  translated. Pinned in `test/gettext_test.exs`.
- **No queries in a page LiveView `mount/3`.** Test host `SelectorHostLive`
  builds scope from params in `mount/3` with no DB (the LC fetches on
  first `update/2`).
- **PR #77 (rustler)** is independent and clean — see that review.

---

## Not done (recorded)

- Starting-quantity field (the real "paint case") does not exist; do not
  revive `default_value` for it.
- Category chip counts, IntersectionObserver sentinel, nested ProductCard,
  paste-a-list bulk add — already on the design deferred list.
- Shared fetch-executor between the two LCs — still waiting for a third
  surface.
