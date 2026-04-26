# Follow-up Items for PR #13

Triaged against `main` on 2026-04-26 after the upstream merge
(commit `6887741`). Single PINCER_REVIEW (also captured in
`AGGREGATED_REVIEW.md`); verdict "✅ APPROVE — clean merge, no
blockers". Four findings — two of them (`#1` MEDIUM and `#2` LOW)
were fixed in this batch.

## Fixed (Batch 1 — 2026-04-26)

- ~~**#1 (MEDIUM)** `lookup_parent/2` does a DB query inside the
  broadcast path~~ — Threaded `parent_catalogue_uuid:` into the
  17 `category.*` and `item.*` `log_activity` callers in
  `lib/phoenix_kit_catalogue/catalogue.ex`. The fallback
  `lookup_parent/2` path now only fires for callers outside this
  module (mix tasks, IEx, future API endpoints) — every in-module
  mutation already has the parent in scope and threads it through
  cheaply (zero extra DB queries).

  Specifically threaded:
  - 8 `category.*` events (`created`, `updated`, `deleted`,
    `trashed`, `restored`, `permanently_deleted`,
    `positions_swapped`, plus 3 `category.moved` paths) →
    `category.catalogue_uuid` / `moved.catalogue_uuid` /
    `target_catalogue_uuid` depending on the move shape.
  - 7 `item.*` events (`updated`, `deleted`, `trashed`, `restored`,
    `permanently_deleted`, plus 2 `item.moved` paths) →
    `item.catalogue_uuid` / `moved.catalogue_uuid` /
    `catalogue_uuid` depending on the move shape.
  - `item.created` already threaded (pre-existing from PR #13).
  - `item.bulk_trashed` carries no `resource_uuid`, so
    `broadcast_for/2` doesn't fan out for it — no parent needed.

  Pinned by 4 new tests in `test/activity_logging_test.exs` —
  `describe "PubSub broadcast carries parent_catalogue_uuid
  (PR #13 #1)"`. Each test subscribes to the catalogue topic,
  performs a mutation, and asserts `assert_receive
  {:catalogue_data_changed, kind, uuid, parent}` with the expected
  `parent` UUID.

- ~~**#2 (LOW)** Duplicate `lookup_parent` between `Catalogue` and
  `Rules`~~ — Extracted `Catalogue.Helpers.item_catalogue_uuid/1`
  as the single source of truth. `Catalogue.lookup_parent(:item, _)`
  now delegates to it; `Rules.item_parent_catalogue_uuid/1` does
  the same. The two queries that did `from(i in Item, where: i.uuid
  == ^uuid, select: i.catalogue_uuid)` in different files are now
  one. Verified by `mix credo --strict` clean and `mix test`
  655/655 passing.

## Skipped (with rationale)

- **#3 (LOW)** `nil` parent fallback overly broad in detail LV —
  by design. The `is_nil(parent)` clause keeps the LV responsive
  to broadcasts from the few remaining external paths
  (`lookup_parent/2` could still return `nil` if the resource was
  deleted between the mutation and the broadcast lookup). After
  fix #1, `nil` is rare, but treating it as "defensive refresh"
  remains the right defensive choice — the alternative (drop the
  message) silently masks bugs. No change.

- **#4 (INFO)** `handle_info` clause restructuring — positive
  cleanup, no action needed.

## Files touched

| File | Change |
|------|--------|
| `lib/phoenix_kit_catalogue/catalogue.ex` | #1 thread `parent_catalogue_uuid:` through 17 `log_activity` callers; #2 `lookup_parent(:item, _)` now delegates to `Helpers.item_catalogue_uuid/1` |
| `lib/phoenix_kit_catalogue/catalogue/helpers.ex` | #2 new `item_catalogue_uuid/1` shared helper |
| `lib/phoenix_kit_catalogue/catalogue/rules.ex` | #2 `item_parent_catalogue_uuid/1` now delegates to the shared helper |
| `test/activity_logging_test.exs` | #1 4 new PubSub broadcast assertions pinning `parent_catalogue_uuid` threading |

## Verification

- `mix compile --warnings-as-errors` clean
- `mix format --check-formatted` clean
- `mix credo --strict` 0 issues, 1138 mods/funs
- `mix test` — 655 tests, 0 failures (was 651 pre-fix; +4 from PubSub
  pinning tests)
- 10/10 stable runs
- Stale-ref greps — `Task.start`, `IO.inspect`, `TODO/FIXME`, raw
  error strings — zero hits
- The Phase 2 quality-sweep commits (`3c8e586` / `b73006a` /
  `17bedb9`) rebased cleanly over PR #13 — no conflicts; the
  threading work landed on top.

## Open

None.
