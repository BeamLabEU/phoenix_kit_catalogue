# PR #14 — Quality sweep follow-up

PR: <https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/14>

The original sweep landed on 2026-04-26 across commits `3c8e586`,
`b73006a`, `17bedb9`, `19afc56`, and `2dae1b9`. Phase 1 PR triage and
Phase 2 sweep notes are recorded in the workspace `AGENTS.md` entry for
this module, in the per-PR FOLLOW_UPs under
`dev_docs/pull_requests/2026/{1..13}-*/`, and in
`dev_docs/sweep_2026_04_*.md`.

This file tracks **re-validation passes** added on top of the original
sweep as the workspace pipeline standard evolves.

---

## Batch 2 — re-validation 2026-04-28

The C12 Explore agents were re-run against current `lib/` and `test/`
under the post-Apr pipeline's named-category prompts (verbatim from
workspace `AGENTS.md`). The original sweep predates several of these
prompts, so the second pass surfaced gaps the first pass didn't have
language for. Phase 1 PR triage was re-verified clean — every per-PR
FOLLOW_UP from #1–#13 still holds against current code.

### Fixed (Batch 2 — 2026-04-28)

- ~~**`EventsLive` had no `handle_info/2` at all.**~~ — added a
  catch-all `Logger.debug` clause in
  `lib/phoenix_kit_catalogue/web/events_live.ex` so any future
  PubSub broadcast (or stray monitor signal) doesn't raise
  `FunctionClauseError`. Pinned by
  `test/web/revalidation_2026_04_28_test.exs`
  "EventsLive catch-all swallows stray messages…" which lifts
  `Logger.level` to `:debug` for the test (test config sets
  `:warning` globally, which filters debug *before* `capture_log`
  sees it — see workspace `AGENTS.md` known-traps).

- ~~**`Catalogue.ActivityLog.log/1` rescue missed
  `DBConnection.OwnershipError` and `catch :exit, _`.**~~ — widened
  to the canonical post-publishing-Batch-5 shape:
  `Postgrex.Error -> :ok` (host hasn't run V90), explicit
  `DBConnection.OwnershipError -> :ok` (async PubSub broadcasts
  crossing into a logging path without sandbox checkout), generic
  `error -> Logger.warning`, plus `catch :exit, _ -> :ok` for
  sandbox-shutdown signals. Pinned by the
  `Batch 2 — ActivityLog rescue widened` describe block, which
  spawns an unowned process and asserts `:ok` with no warning log.

- ~~**`"Markup Override (%)"` was extractor-invisible.**~~ — added
  `defp translate_target("Markup Override (%)"), do: gettext(…)`
  in `import_live.ex`. The label originated from
  `Mapper.available_targets/0` and fell through the `_label, do:
  label` catch-all, which means `mix gettext.extract` never saw
  it. Pinned by a meta-test that diffs every label returned by
  `Mapper.available_targets/0` against literal `defp
  translate_target("…")` clauses, so a future label addition
  fails loud rather than ships silently English-only.

- ~~**Five destructive `phx-click` buttons missing
  `phx-disable-with`.**~~ — added on `remove_file`
  (`catalogue_form_live.ex:603`, `item_form_live.ex:1100`),
  `remove_meta_field` (`components.ex` × 2 — active + legacy
  rows), `clear_featured_image` (`components.ex:168`), and
  `clear_file` (`import_live.ex:1521`). Each pinned by a
  source-level `Regex.scan` so a regression on any one revert
  fails the corresponding test.

- ~~**`mix.exs` had no `test_coverage [ignore_modules]`
  filter.**~~ — added the canonical filter excluding
  `~r/^PhoenixKitCatalogue\.Test\./`, `DataCase`, `LiveCase`, and
  `ActivityLogAssertions`. Matches the
  `phoenix_kit_document_creator` / `phoenix_kit_publishing` shape;
  `mix test --cover` now reports production-only coverage.

- ~~**No PubSub `handle_info` smoke tests for the catalogue's six
  admin LVs.**~~ — added catch-all + real-broadcast smoke tests
  for `EventsLive`, `CataloguesLive`, `CatalogueDetailLive`,
  `CatalogueFormLive`, `CategoryFormLive`, `ItemFormLive`, and
  `ImportLive`. Each test `send/2`s a real-shape PubSub message
  (or an unexpected message for the catch-all path) directly to
  `view.pid` and re-renders so the LV's handler actually runs.
  Without this, a stale field reference inside any clause would
  surface only when a second admin tab opened the same record —
  the workspace `AGENTS.md` C10 trap referenced from the entities
  sweep.

### Files touched

| File | Change |
|------|--------|
| `lib/phoenix_kit_catalogue/web/events_live.ex` | `require Logger` + catch-all `handle_info/2` clause |
| `lib/phoenix_kit_catalogue/catalogue/activity_log.ex` | widened rescue + `catch :exit, _` |
| `lib/phoenix_kit_catalogue/web/import_live.ex` | "Markup Override (%)" translate clause + `phx-disable-with` on `clear_file` |
| `lib/phoenix_kit_catalogue/web/catalogue_form_live.ex` | `phx-disable-with` on `remove_file` |
| `lib/phoenix_kit_catalogue/web/item_form_live.ex` | `phx-disable-with` on `remove_file` |
| `lib/phoenix_kit_catalogue/web/components.ex` | `phx-disable-with` on `remove_meta_field` × 2 + `clear_featured_image` |
| `mix.exs` | `test_coverage: [ignore_modules: […]]` filter |
| `test/web/revalidation_2026_04_28_test.exs` | new file — 16 pinning tests for every Batch 2 delta |

### Verification

- `mix test` — 671 / 0 failures (655 → 671, +16 from the new
  pinning file)
- `mix format --check-formatted` — clean (post-format run)
- `mix credo --strict` — 1142 mods/funs, 0 issues
- `mix dialyzer` — 0 errors
- Pre-existing `DBConnection.OwnershipError` warning from core's
  `Settings.get_boolean_setting/2` for `catalogue_enabled` is still
  present in test stderr (matches the AI module precedent at
  workspace AGENTS.md line 1393–1399 — suppression lives upstream).

### Open

None.

---

## Batch 3 — fix-everything pass 2026-04-28

C12 agents surfaced several findings classified by Batch 2 as "fix in
Batch 3". The default-mode sweep would surface those as deferred per
`feedback_quality_sweep_scope.md`, but the canonical re-validation
pattern across modules has been to do the fix-everything pass when the
findings are mechanical wins or pin already-correct behaviour.

### Fixed (Batch 3 — 2026-04-28)

- ~~**`PhoenixKitCatalogue.Catalogue` had 26 public functions without
  `@spec`.**~~ — backfilled. The full public API is now type-annotated:
  `list_catalogues/1`, `list_catalogues_by_name_prefix/2`,
  `deleted_catalogue_count/0`, `get_catalogue!/2`,
  `list_categories_for_catalogue/1`,
  `list_categories_metadata_for_catalogue/2`,
  `list_items_for_category_paged/2`,
  `list_uncategorized_items_paged/2`,
  `uncategorized_count_for_catalogue/2`, `item_count_for_category/2`,
  `item_counts_by_category_for_catalogue/2`, `list_all_categories/0`,
  `get_category!/1`, `delete_category/2`, `trash_category/2`,
  `restore_category/2`, `permanently_delete_category/2`,
  `next_category_position/2`, `list_items/1`,
  `list_items_for_category/1`, `list_items_for_catalogue/1`,
  `list_uncategorized_items/2`, `get_item!/1`, `delete_item/2`,
  `restore_item/2`, `permanently_delete_item/2`,
  `trash_items_in_category/2`. `mix dialyzer` clean. The submodules
  (`Helpers`, `Rules`, `Tree`, `Counts`, `Links`, `Manufacturers`,
  `Suppliers`, `ActivityLog`, `PubSub`, `Search`, `Translations`)
  were already at 100% spec coverage from the original sweep.

- ~~**Broad `rescue e ->` in the supervised import task.**~~ —
  narrowed to `[ArgumentError, RuntimeError, Ecto.InvalidChangesetError,
  Ecto.QueryError, Postgrex.Error]` in
  `lib/phoenix_kit_catalogue/web/import_live.ex`. A bare rescue would
  also swallow programmer-error exceptions like `KeyError` /
  `FunctionClauseError` from a future refactor — those should crash
  the supervised task so the supervisor logs the full stacktrace and
  the bug surfaces.

- ~~**No edge-case tests for free-text fields (Unicode round-trip,
  LIKE metacharacters in user input, over-length names, embedded
  null bytes).**~~ — new `test/edge_cases_test.exs` (13 tests):
  - `Helpers.sanitize_like/1` — LIKE metacharacter escapes (`%`,
    `_`, `\`) plus combined metas. Pins the existing escape
    contract so a future refactor surfaces.
  - `search_items/2` Unicode round-trip — CJK, emoji, RTL Hebrew.
  - `search_items/2` LIKE metacharacters — `%` and `_` literal-not-
    wildcard, single-quote SQL-injection probe (parameter binding
    safety), leading `%` not interpreted as a wildcard.
  - `search_items/2` empty input — pins the "matches everything"
    behaviour so a future tightening surfaces.
  - `create_catalogue/2` — 256-char name returns `{:error,
    %Ecto.Changeset{}}`, never raises (canonical Coverage-push
    pattern #1: tighten contract → clean error tuple).
  - `create_item/2` — Unicode name persists exactly through DB
    round-trip.

### Files touched

| File | Change |
|------|--------|
| `lib/phoenix_kit_catalogue/catalogue.ex` | +27 `@spec` declarations on the public API |
| `lib/phoenix_kit_catalogue/web/import_live.ex` | narrowed `rescue` clause in supervised import task |
| `test/edge_cases_test.exs` | new file — 13 edge-case tests for free-text fields |

### Verification

- `mix test` — 671 → 684 (+13), 0 failures
- `mix format --check-formatted` — clean
- `mix credo --strict` — 1143 mods/funs, 0 issues
- `mix dialyzer` — 0 errors

### Open

None. The error-branch activity logging design tension is surfaced
below for Max's call — Batch 3 lands the rest of the fix-everything
pass independent of the (A)/(B) decision.

---

## Surfaced for Max — needs a call

**Error-branch activity logging design tension.** The catalogue's
`ActivityLog` module documents a deliberate success-only logging
convention at `activity_log.ex:8–14`:

> Convention: this module logs on **success** only. Failed mutations
> surface as `{:error, _}` to the LiveView, which logs the rich error
> context via its own `log_operation_error/3` (see
> `web/catalogue_detail_live.ex:425`). The activity log is the user-
> visible audit trail; operation errors are an engineer-visible log
> stream. Keeping the two separate prevents validation noise from
> drowning the audit feed.

The post-Apr pipeline's C12 agent #2 prompt now requires:

> Every CREATE / UPDATE / DELETE / status-change context fn must log
> on BOTH `:ok` AND `:error` branches (the `:error` branch should log
> with a `db_pending` or similar flag so the audit trail covers the
> user-initiated action even when the cache write fails).

Both are reasonable. Picking one needs Max's call:

- **(A) Override the catalogue's design** — add `:error`-branch
  logging across all CRUD mutations (~12–15 sites: `create_catalogue`,
  `update_catalogue`, `delete_catalogue`, `trash_catalogue`,
  `restore_catalogue`, `permanently_delete_catalogue`,
  `create_category`, `update_category`, `delete_category`,
  `trash_category`, `restore_category`,
  `permanently_delete_category`, `move_category_under`,
  `move_category_to_catalogue`, plus the item / smart-rule
  equivalents). Match
  `phoenix_kit_publishing` / `phoenix_kit_document_creator` /
  `phoenix_kit_sync` precedent.
- **(B) Keep the catalogue's intentional split** — document the
  exception in `AGENTS.md` (workspace + module) so future
  re-validation passes don't keep flagging it. The
  `log_operation_error/3` flow already gives the engineer-side audit
  channel; the `Activity` feed stays user-visible only.

Batch 3 (fix-everything pass — `@spec` backfill on
`PhoenixKitCatalogue.Catalogue` public API, narrowed broad rescue in
`import_live.ex:1087`, edge-case tests on free-text fields) landed
independent of this — see Batch 3 section above.

