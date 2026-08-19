# Follow-up: PR #61 — Main image thumbnail preview

Triaged 2026-08-19 (quality-sweep Phase 1). Source review: `CLAUDE_REVIEW.md`.

## Fixed (pre-existing)

Every finding was already implemented in current code before this triage:

- ~~BUG MEDIUM: `photo_click` sent `{:item_picker_photo_click, id, nil}` upward when nothing selected~~ — `item_picker.ex:312–317` guards on `{true, %Item{} = item}`; pinned by `test/web/item_picker_card_test.exs:59`.
- ~~IMPROVEMENT MEDIUM: two dead clauses dialyzer rejected (`open_card/2` nil fallback, `read_uuid/2` non-map fallback)~~ — single clauses remain at `item_picker.ex:416` and `product_card.ex` (removal rationale in the comment above `read_uuid`).
- ~~observation: `?q=`/`?category=` URL-state patches leaked `&uuid=`~~ — fixed upstream in core (`phoenix_kit` #719, `url_state.ex` `extras_from_uri/2` reads the query string only); pinned by `test/web/catalogue_detail_live_test.exs:781` and `:800`.
- ~~observation: `reorder_catalogues` did not persist the dropped order~~ — `view_config.ex:175` no-user guard + handler guard `catalogues_live.ex`; pinned by `test/web/catalogues_live_test.exs:738`.

## Skipped (with rationale)

None.

## Open

None. Environment note from the triage: `deps/phoenix_kit` on disk can lag `mix.lock` — run `mix deps.get` (or use `PHOENIX_KIT_PATH=../phoenix_kit`, which every documented test invocation in this workspace does) before reproducing the URL-state tests.
