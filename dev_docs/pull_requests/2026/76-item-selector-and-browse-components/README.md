# PR #76: Add the item selector modal and embeddable browse components

**Author**: @mdon
**Reviewer**: Grok
**Status**: Merged
**Commit**: `c6fbd1f` (`d1d3c7d` on `mdon/feat/item-selector-and-browse-components`)
**Date**: 2026-08-22

## Goal

Ship a client-facing "pick items with quantities" modal (the catalogue's
`MediaSelectorModal` analogue) and the embeddable browse stack it is
assembled from, so a host LiveView can drop a scoped catalogue surface onto
any logged-in page.

## What Was Changed

| File | Change |
|------|--------|
| `lib/phoenix_kit_catalogue/catalogue/browse_state.ex` | Pure reducer: scope, search, category, offset paging, generation counter |
| `lib/phoenix_kit_catalogue/web/components/browse.ex` | Function components: card, grid, chips, qty stepper, skeleton, `present_items/2` |
| `lib/phoenix_kit_catalogue/web/components/item_selector_modal.ex` | LiveComponent modal picker with tray + confirm |
| `lib/phoenix_kit_catalogue/web/components/catalogue_browse.ex` | LiveComponent browse surface without selection chrome |
| `lib/phoenix_kit_catalogue/web/components.ex` | Moduledoc index of the new surfaces |
| `priv/gettext/{default.pot,en,et,ru}` | New strings + one pre-existing gap |
| `test/catalogue/browse_state_test.exs` | Reducer {command, scope-shape} product |
| `test/web/browse_components_test.exs` | Render contracts |
| `test/web/item_selector_modal_test.exs` | Host-message contract + adversarial clamps |
| `test/web/catalogue_browse_test.exs` | Embeddable browse through the same test host |
| `test/support/selector_host_live.ex` | Test-only host LiveView |
| `dev_docs/design/2026-08-22-item-selector-and-browse-components.md` | Design notes + deferred list |

## Implementation Details

Three layers so the picker and any embedded browse cannot drift:

1. `Catalogue.BrowseState` — no process, no queries. Commands return
   `{:fetch, opts, gen}` or `:noop`; the caller runs the query and
   `ingest/4`s.
2. `Web.Components.Browse` — pure function components, all take `target`.
3. Two LiveComponents as thin glue. Nested LiveComponents were rejected
   because `send(self(), …)` from a nested LC lands in the root LV.

Scope is a security boundary: fixed at init, every fetch re-derived from it,
selection accepts only uuids the component itself rendered (or hydrated
preselects). Quantities are `Decimal` end to end, clamped server-side.

## Testing

- [x] Unit tests added/updated (reducer, render contracts)
- [x] Integration tests pass (LiveComponents driven through `SelectorHostLive`)
- [x] Gettext catalogues updated by hand (en/et/ru)
- [x] Post-merge review findings fixed and pinned (see `GROK_REVIEW.md`)

## Related

- Design: `dev_docs/design/2026-08-22-item-selector-and-browse-components.md`
- Review: [GROK_REVIEW.md](GROK_REVIEW.md)
- Sibling: [#77](/dev_docs/pull_requests/2026/77-rustler-declare)
