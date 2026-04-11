# PR #7 Review — Catalogue refactor: items belong directly to catalogues, infinite scroll, comprehensive test suite, UX polish

**Reviewer:** Pincer 🦀
**Date:** 2026-04-11
**Verdict:** Approve with observations

---

## Summary

Major refactor of phoenix_kit_catalogue. 38 files, +5610/-573 lines.

1. Items now have a direct `catalogue_uuid` FK — derived from category on create/update, no longer inferred through associations
2. Infinite scroll with cursor-based pagination on catalogue detail page (IntersectionObserver + `load_next_batch/1`)
3. Activity logging via `EventsLive` tab with `actor_uuid` threaded through all mutations
4. ~230 new test cases covering catalogue_uuid derivation, cascades, paged queries, LiveView interactions
5. UX: item counts on catalogue list, clickable entity names, catalogue field in item tables, i18n fixes

---

## What Works Well

1. **Clean `catalogue_uuid` derivation** — Items get their catalogue from their category automatically via `derive_catalogue_uuid/1`. The `ensure_catalogue_uuid/1` migration helper backfills existing items. Consistent with V96 migration.
2. **Infinite scroll is well-designed** — Cursor walks categories → uncategorized → done. `merge_category_card/2` and `merge_uncategorized_card/2` correctly append to existing cards. Sentinel element with IntersectionObserver is clean.
3. **Comprehensive test coverage** — `catalogue_test.exs` alone has 750+ new lines. Tests cover edge cases: string-keyed form params, cross-catalogue moves, cascade behavior, empty categories. LiveView tests use a proper `LiveCase` setup with test router/endpoint.
4. **Activity logging** — `actor_opts/1` consistently passes user UUID through all mutation functions. Events are queryable per catalogue.
5. **Removed `safe_nested_assoc/2`** — The direct `catalogue` association on items makes the code simpler and queries more explicit.

---

## Issues and Observations

### Design (non-blocking)

1. **`actor_opts/1` duplicated across 7 LiveViews** — Same 5-line function copied into `catalogue_detail_live.ex`, `catalogue_form_live.ex`, `catalogues_live.ex`, `category_form_live.ex`, `import_live.ex`, `item_form_live.ex`, `manufacturer_form_live.ex`, `supplier_form_live.ex`. Should be extracted to a shared module (e.g., `PhoenixKitCatalogue.Web.Helpers` or a `import`-able macro). Not blocking — works correctly, just maintenance burden.

2. **`InfiniteScroll` JS hook defined inline in two places** — `catalogue_detail_live.ex` and `events_live.ex` both embed the same `<script>` block with the IntersectionObserver. Should be in a shared JS file or registered once. Works fine but duplicating JS is fragile.

3. **Cursor state is in assigns, not URL params** — The infinite scroll cursor (`phase`, `category_index`, `item_offset`) lives in socket assigns. If a user navigates away and back, they lose their scroll position. This is a UX trade-off, not a bug — LiveView doesn't make URL-based scroll state easy.

### Style (minor)

4. **`reset_and_load/1` calls `load_next_batch/1` at the end** — This means mount triggers an immediate second query batch. The first `reset_and_load` call sets up assigns and loads the first batch synchronously. This is fine for the initial render but worth noting that mount does 2+ DB round trips.

5. **Several `else` branches omit `load_catalogue_data`/`reset_and_load`** — Some error handlers now return the socket without reloading data (e.g., `restore_category` error branch). This means stale data could show after a failed mutation. The user sees a flash error, which is probably fine, but worth being aware of.

---

## Post-Review Status

No blockers. Solid refactor with excellent test coverage. The duplicated `actor_opts/1` and inline JS are the main maintainability concerns — both easy to clean up in a follow-up PR.
