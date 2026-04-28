# C11 Delta Audit (2026-04-26)

For every modified production file in this branch's diff, the test
that would fail if the change reverted. Built per the C11 step in the
workspace AGENTS.md playbook.

## Production code changes

| File | Change | Pinning test |
|------|--------|--------------|
| `lib/phoenix_kit_catalogue.ex` | C4 — `enable_system` / `disable_system` log `catalogue_module.enabled` / `.disabled` | `test/activity_logging_test.exs:"module toggle"` (12 tests' last block) |
| `lib/phoenix_kit_catalogue.ex` | C4 — `enabled?/0` adds `catch :exit, _` for sandbox shutdown | (Indirect) the 10-run stability check in the final checklist exposes the 1-in-10 race |
| `lib/phoenix_kit_catalogue/catalogue/activity_log.ex` | C4 — moduledoc + narrowed `Postgrex.Error` rescue | (Documentation; covered by absence of `:undefined_table` warnings in C7 baseline) |
| `lib/phoenix_kit_catalogue/catalogue.ex` | C6 — TOCTOU `move_category_under/3` cycle re-check inside transaction with FOR UPDATE | `test/catalogue_test.exs:"update_category/3 rejects a parent that is a descendant (cycle)"` (re-runs after transaction commits) |
| `lib/phoenix_kit_catalogue/catalogue.ex` | C6 — `swap_category_positions/3` FOR UPDATE on both rows | (Existing swap tests; race condition not covered by deterministic test — see `agents.md` "concurrency tests don't compose with Sandbox") |
| `lib/phoenix_kit_catalogue/catalogue.ex` | C6 — `cycle?/2` helper normalises Tree CTE binary vs textual UUID | `test/catalogue_test.exs:"update_category/3 rejects a parent that is a descendant (cycle)"` |
| `lib/phoenix_kit_catalogue/catalogue.ex` | C6 — Missing `@spec` on 4 public fns (restore_catalogue, change_catalogue, change_category, change_item, move_category_to_catalogue, move_item_to_category) | `mix dialyzer` (no untyped public fns in catalogue.ex) |
| `lib/phoenix_kit_catalogue/catalogue/rules.ex` | C7 — `list_items_referencing_catalogue/1` query rerooted at `Item` to satisfy newer Ecto preload binding requirement | `test/catalogue_test.exs:"list_items_referencing_catalogue/1 and catalogue_reference_count/1 ..."` (3 tests) |
| `lib/phoenix_kit_catalogue/catalogue/tree.ex` | C7 — recursion query in `ancestor_uuids/1` casts `^uuid` via `type(^uuid, UUIDv7)` | `test/catalogue_test.exs:"restore_category cascades ..."` (multiple tests in the cascade family — would fail with `Postgrex expected a binary of 16 bytes`) |
| `lib/phoenix_kit_catalogue/catalogue/tree.ex` | C6 — Removed redundant `Map.new(...)` after `Enum.group_by` | (Behaviour unchanged; verified by all existing nested-category tests) |
| `lib/phoenix_kit_catalogue/import/parser.ex` | C3 — error returns converted to atoms / tagged tuples | `test/errors_test.exs` Errors module pins; `test/import/mapper_test.exs:"reports error for missing name"` and `:"rejects unparseable markup values"` |
| `lib/phoenix_kit_catalogue/import/mapper.ex` | C3 — same atom conversion | Same as above |
| `lib/phoenix_kit_catalogue/web/import_live.ex` | C3 — uses `Errors.message/1` for sheet/file parse flashes; `translate_error/1` simplified to delegate | `test/errors_test.exs` (every atom maps to a string); behavioural — flashes still surface a translated string |
| `lib/phoenix_kit_catalogue/web/import_live.ex` | C6 — `Task.start` → `Task.Supervisor.start_child(PhoenixKit.TaskSupervisor, ...)` | `grep "Task.start"` in the final-checklist sweep returns zero hits |
| `lib/phoenix_kit_catalogue/web/import_live.ex` | C6 — `actor_opts/1` now reuses shared `actor_uuid/1` from Helpers | (Behaviour unchanged; existing import tests still pass) |
| `lib/phoenix_kit_catalogue/web/catalogue_detail_live.ex` | C6 — local `actor_opts/1` + `actor_uuid/1` removed; imported from Helpers | `test/activity_logging_test.exs` (every action sees the right actor_uuid) |
| `lib/phoenix_kit_catalogue/web/catalogue_detail_live.ex` | C6 — `handle_info/2` catch-all → `Logger.debug` | `test/web/sweep_delta_test.exs:"stray messages don't crash CataloguesLive"` (catch-all stays exhaustive) |
| `lib/phoenix_kit_catalogue/web/catalogue_form_live.ex` | C6 — local `actor_opts/1` removed; imported | Same |
| `lib/phoenix_kit_catalogue/web/catalogue_form_live.ex` | C6 — `handle_info/2` → `Logger.debug` | Same |
| `lib/phoenix_kit_catalogue/web/catalogues_live.ex` | C6 — local helpers removed; `String.capitalize(c.status)` → `status_label(c.status)` (4 sites) | `test/web/sweep_delta_test.exs:"catalogue card view renders translated 'Active' status, not raw 'active'"` |
| `lib/phoenix_kit_catalogue/web/catalogues_live.ex` | C6 — `handle_info/2` → `Logger.debug` | Same |
| `lib/phoenix_kit_catalogue/web/category_form_live.ex` | C6 — local helpers removed; `mount_attachments(category, files_grid: false)` (PR #12 #1 fix) | (Behaviour: no DB query for files-grid on Category form mount; verified by removing query log line in dev) |
| `lib/phoenix_kit_catalogue/web/category_form_live.ex` | C6 — `handle_info/2` → `Logger.debug` | Same |
| `lib/phoenix_kit_catalogue/web/components.ex` | C5 — `phx-disable-with="Deleting..."` on perm-delete buttons (inline + table-row-menu) | `test/web/sweep_delta_test.exs:"components.ex source pins the perm-delete phx-disable-with attr"` |
| `lib/phoenix_kit_catalogue/web/components.ex` | C5 — `search_input` placeholder default → `nil`, resolved to `gettext("Search...")` | (Source-level pin; existing component_test still passes) |
| `lib/phoenix_kit_catalogue/web/components.ex` | C6 — `String.capitalize(item.status)` → `status_label(item.status)` (card field) | `test/web/components_test.exs:"renders with an unknown status"` (assert raw key for unknown) |
| `lib/phoenix_kit_catalogue/web/components.ex` | C6 — `String.capitalize(other)` and `column_label` raw fallback dropped | `test/web/components_test.exs:"renders with an unknown status"` |
| `lib/phoenix_kit_catalogue/web/events_live.ex` | C6 — `String.capitalize(other)` removed in `humanize_resource_type` fallback | (No direct test; structural) |
| `lib/phoenix_kit_catalogue/web/item_form_live.ex` | C6 — local helper removed; `handle_info/2` → `Logger.debug` | (Existing tests pass) |
| `lib/phoenix_kit_catalogue/web/manufacturer_form_live.ex` | C6 — local helper removed | Same |
| `lib/phoenix_kit_catalogue/web/supplier_form_live.ex` | C6 — local helper removed | Same |
| `lib/phoenix_kit_catalogue/attachments.ex` | C6 — `mount_attachments/3` `:files_grid` opt; CategoryFormLive passes `false` | (Behaviour-only; no per-mount DB query for Category form. Manual verification) |

## New production modules

| File | Pinning test |
|------|--------------|
| `lib/phoenix_kit_catalogue/errors.ex` | `test/errors_test.exs` (one test per atom + tagged tuples + pass-through) |
| `lib/phoenix_kit_catalogue/web/helpers.ex` | `test/web/helpers_test.exs` (status_label + actor_opts + actor_uuid) |

## Test infrastructure changes

| File | Purpose |
|------|---------|
| `test/test_helper.exs` | C7 — runs migrations on startup; starts `PhoenixKit.PubSub`; adds `pgcrypto` extension |
| `test/support/test_layouts.ex` | C7 — renders `flash-info` / `flash-error` / `flash-warning` divs |
| `test/support/data_case.ex` / `test/support/live_case.ex` | C9 — import `ActivityLogAssertions` |
| `test/support/activity_log_assertions.ex` | C9 — new `assert_activity_logged/2` + `refute_activity_logged/2` helpers |
| `test/support/postgres/migrations/20260318172857_phoenix_kit_settings.exs` | C7 — settings table mirroring core's V41 |
| `test/support/postgres/migrations/20260318172859_phoenix_kit_storage.exs` | C7 — storage tables stub for `MediaSelectorModal` queries |
| `test/support/postgres/migrations/20260422000000_add_v103_nested_categories.exs` | C7 — V103 self-FK on categories |

## Updated tests

| File | Reason |
|------|--------|
| `test/import/mapper_test.exs` | C3 atom errors — assertions changed from string match to atom / tagged tuple |
| `test/web/components_test.exs` | C6 status_label fallback — unknown status now raw key, not `String.capitalize` form |
| `test/web/item_form_live_test.exs` | Pre-existing test bug — smart-item form hides `base_price`/`unit`; tests now omit those fields |

## Test count delta

| State | Tests | Failures |
|-------|-------|----------|
| C0 baseline | 598 | 324 |
| Post-C7 | 598 | 0 |
| Post-C8 (+ Errors per-atom) | 632 | 0 |
| Post-C9 (+ activity logging per-action) | 644 | 0 |
| Post-C10 (+ sweep delta pinning) | 647 | 0 |

## Verification

- `mix compile --warnings-as-errors` — clean
- `mix format --check-formatted` — clean
- `mix credo --strict` — 0 issues (1102 mods/funs)
- `mix test` — 647 tests, 0 failures (will be re-checked under multi-run stability in the final checklist)
