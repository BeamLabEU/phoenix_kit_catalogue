# Review — PR #28: Catalogue folders, detail drill-down rework, and quality sweep

**Merge commit:** `49b45e3` · **Reviewed against:** local `main` (post-merge, core dep already at V123)
**Skills applied:** `elixir-thinking`, `phoenix-thinking`, `ecto-thinking`

## Scope

+4213 / −1777 across 27 files. The substantive new logic is the **catalogue
folders** feature: a module-global self-nesting folder tree (`Schemas.Folder`,
`phoenix_kit_cat_folders`) surfaced as an inline tree-table on `/admin/catalogue`,
plus the detail-page drill-down rework. Review concentrated on the folder
context functions (`catalogue.ex`), the folder schema, PubSub fan-out, and the
two LiveViews (`catalogues_live`, `catalogue_detail_live`).

## Overall assessment

Strong, careful work. Notably:

- **Lifecycle is correct.** Both `mount/3`s only `assign` defaults + subscribe
  (guarded by `connected?/1`); every DB load lives in `handle_params/3`. No
  query-in-mount anti-pattern. (phoenix-thinking Iron Law ✓)
- **PubSub is centralised.** Folder mutations broadcast `:folder` via the
  `log_activity → broadcast_for` pairing, closing the "logged but not broadcast"
  gap the PR set out to fix. Minimal payloads, no field-level leakage.
- **Orphan promotion is consistent** across folders, categories, and catalogues
  (a child of a trashed parent re-roots rather than vanishing), and the
  in-memory subtree walk (`folder_subtree_uuids` / `walk_folder_subtree`) is
  cycle-safe via a visited accumulator.
- **Cross-context reference is by ID** (`folder_uuid`, `parent_uuid`), with
  `ON DELETE SET NULL` at the DB layer — matches ecto-thinking guidance.
- The smart-pricing test de-brittling (`f657555`) is a genuine improvement:
  it now asserts the function's contract, not version-dependent `Decimal`
  internals.

## Findings fixed in this follow-up

### 1. Redundant queries in the index render (perf + consistency) — FIXED

`load_data(:index)` and its helpers issued three avoidable folder/catalogue
queries on **every** index render and PubSub-driven reload:

- `build_active_rows/1` and `folder_options/0` each ran their own identical
  `Catalogue.list_folder_tree(mode: :active)` — two passes over the full folder
  table per render.
- `build_active_rows/1` additionally called `Catalogue.folder_catalogue_counts/0`
  (a `GROUP BY` over catalogues) to label folder rows, while it had **already**
  loaded every catalogue via `catalogues_by_folder/0`.

Fix:
- Load the active tree once in `load_data/2` and thread it into both
  `build_active_rows/2` and `folder_options/1`.
- Derive per-folder counts from the already-loaded `cats_by_folder` map
  (`Map.new(cats_by_folder, fn {uuid, cats} -> {uuid, length(cats)} end)`).

This removes two DB round-trips per index render and makes the displayed count
and the rendered children **consistent by construction** (previously they were
two separate queries that could, in principle, disagree).

### 2. Dead code — FIXED

- `Catalogue.list_child_folders/2` — added in this PR, zero callers in `lib/`
  or `test/`. Removed.
- `Catalogue.folder_catalogue_counts/0` — its only caller was the index render
  above; removed alongside finding #1.

Both were new in this PR, so removing them retires unused surface before anything
depends on it. (per [[feedback_dep_constraints]]-style "don't ship speculative
surface" hygiene)

**Verification of fixes:** `mix compile --warnings-as-errors`, `mix format`, and
`mix credo --strict` all clean. Behaviour of the affected functions is unchanged
(counts are arithmetically identical; folder-row lookups only ever key on an
*active* folder's uuid, for which `catalogues_by_folder` never re-roots).

## Observations left as-is (not fixed)

- **Self-echo reload.** The `{:catalogue_data_changed, …}` events carry no
  `from`-pid, so the LV that originated a folder mutation also reloads on its
  own broadcast (a second, redundant `load_data`). The heavier card/bulk
  broadcasts already use a `from != self()` skip; the lightweight events
  deliberately don't. Harmless on an admin-only page; flagging for awareness,
  not worth the extra socket plumbing.
- **`next_folder_position` / `front_folder_position` are unsynchronised**
  (`max + 1` / `min − 1` without a lock). Concurrent creates in the same level
  can tie; ties break on `name` and a manual reorder normalises to `1..N`, so
  it's benign. Negative positions from repeated front-insertion are likewise
  cosmetic.
- **No `psql`/Postgres in the review sandbox**, so the 1089-test suite could
  not be executed locally (`test_helper.exs` shells out to `psql`). The fixes
  touch no tested public function — `folders_test.exs` exercises
  `list_folder_tree`, `catalogues_by_folder`, and `folder_uuids_with_children`,
  all retained — but the suite should be run in CI against the V123 core
  release before relying on this.

## Recommendation

Folder feature is well-designed and the lifecycle/PubSub patterns are sound.
The two follow-up fixes are low-risk cleanups (fewer queries, less dead code).
Run the full suite in CI once the V123 core release lands to confirm green
end-to-end.
