# PR #49 — Put the catalogue list search and filters in the URL

Merged as `3377b9e` (branch `feature/url-state-search`, commits `e0c0240` +
`f5643f0`, author @timujinne).

## Goal

Move the admin list screens' transient search/filter state out of socket
assigns and into the address bar, so a filtered list is a real URL: shareable,
bookmarkable, reproduced by a reload, and left by the Back button.

## What changed

Three LiveViews adopt `PhoenixKitWeb.Live.UrlState` (core, `:patch` mode):

| LiveView | Declared params |
|---|---|
| `CatalogueDetailLive` | `current_category_uuid` → `?category=`, `search_query` → `?q=` |
| `CataloguesLive` | `search_query` → `?q=` |
| `PdfLibraryLive` | `filter` → `?filter=` (whitelist `active`/`trashed`), `search` → `?q=` |

Mechanically, in each: the assign is dropped from `mount/3` (UrlState assigns it
via `on_mount` before `mount` runs), `handle_params/3` becomes an explicit
`{:noreply, socket}` stub (required because these modules annotate `@impl`, and
the macro-injected stub carries none), the old `handle_params` body moves into
`handle_url_state/2`, and the search/filter event handlers become
`push_url_state/3` calls — `replace: true` for the debounced search boxes so
Back doesn't walk the query backwards a few characters at a time.

`?category=` was already a URL param on the detail page; the change there is
that `?q=` joins it and that node-change detection now goes through an explicit
`prior_category_uuid` assign rather than diffing `current_category_uuid`
(UrlState overwrites that assign before the callback runs, so it can no longer
serve as the "what was loaded last" marker).

## Non-obvious implementation choices

- **`prior_filter` / `prior_category_uuid` guards.** `handle_url_state/2` fires
  on every declared-state change, including one per debounce pause while
  typing. Both screens therefore gate their DB work on a *structural* change:
  `PdfLibraryLive` re-runs `list_pdfs/1` only when `?filter=` moves (the search
  is applied client-side by `filter_by_search/2` at render), and
  `CatalogueDetailLive` re-resolves and reloads the level only when
  `?category=` moves. Commit `f5643f0` is exactly this fix for the PDF screen,
  which `e0c0240` had regressed into a query per keystroke pause.
- **`CataloguesLive` keeps tab identity in `live_action`, not in the query.**
  The three tabs are separate routes, so the scope is already in the path and a
  single `?q=` is unambiguous. `tab_changed?` guards `load_data/2` for the same
  reason as above.

## Post-merge review

See [`CLAUDE_REVIEW.md`](./CLAUDE_REVIEW.md) — two fixes applied on top
(`?category=` normalization, stranded search results), plus a test-harness fix
that had been blocking `mix test` on machines without `psql`.

## Related PRs

- Previous: [#48](../48-ai-multilang-tabs-migration)
