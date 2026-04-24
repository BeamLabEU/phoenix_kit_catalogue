# PR #10: Smart catalogues + context split + admin LV hardening

**Author**: @mdon (Max Don)
**Reviewer**: @fotkin (Dmitri)
**Status**: Merged
**Merge commit**: `be25fe9` (`b5e1cb0` on mdon/main)
**Date**: 2026-04-20
**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/10

## Goal

Three coherent threads shipped together:

1. **Smart catalogues** — `kind: "smart"` catalogues whose items are priced as a rule-driven function of other catalogues. Introduces a new `CatalogueRule` schema, per-leg value/unit inheritance, and a force-delete guard protecting against FK cascades.
2. **Context split** — extract the monolithic `catalogue.ex` into 10 focused submodules. Public surface preserved via `defdelegate` — zero caller churn.
3. **Admin LV hardening** — replace the raising `confirm_delete!/1` pattern with a safe case-match + fallback handler (directly closes PR #7 review bug #3), add structured `log_operation_error/3` to both admin LVs, guard `ActivityLog.log/1` with rescue, `phx-disable-with` on destructive actions.

Requires core phoenix_kit 1.7.102+ for the V102 migration.

## What Was Changed

35 files, +5427 / −1720.

| File | Change |
|------|--------|
| `lib/phoenix_kit_catalogue/schemas/catalogue_rule.ex` | **New.** `CatalogueRule` — one row per `(item, referenced_catalogue)` pair; nullable `value`/`unit` with `effective/2` fallback to `item.default_value` / `item.default_unit` |
| `lib/phoenix_kit_catalogue/schemas/cat_catalogue.ex` | `kind` (`"standard" \| "smart"`), `discount_percentage` |
| `lib/phoenix_kit_catalogue/schemas/item.ex` | `discount_percentage` (nullable override), `default_value`, `default_unit`, `has_many :catalogue_rules`; new `final_price/3`, `effective_discount/2`, `discount_amount/3` |
| `lib/phoenix_kit_catalogue/catalogue.ex` | Shrinks from 797 → 338 lines; now a delegate façade + pricing helpers + cross-submodule soft-delete cascades; `permanently_delete_catalogue/2` gains `{:error, {:referenced_by_smart_items, count}}` guard + `:force` option |
| `lib/phoenix_kit_catalogue/catalogue/rules.ex` | **New.** `put_catalogue_rules/3` (atomic replace-all via `Ecto.Multi`), `list_catalogue_rules/1`, `catalogue_rule_map/1`, `list_items_referencing_catalogue/1`, `catalogue_reference_count/1`, single-rule CRUD |
| `lib/phoenix_kit_catalogue/catalogue/activity_log.ex` | **New.** `log/1` wraps `PhoenixKit.Activity.log/1` in `try/rescue` + `Logger.warning` — never crashes the primary op |
| `lib/phoenix_kit_catalogue/catalogue/{search,counts,pub_sub,helpers,manufacturers,suppliers,links,translations}.ex` | **New.** Section extractions; public surface re-exported from `Catalogue.*` |
| `lib/phoenix_kit_catalogue/web/item_form_live.ex` | Smart-catalogue rule picker (`toggle/set_value/set_unit/clear` events + `working_rules` assign → `put_catalogue_rules/3` on save); smart-item move-to-catalogue path; `<.input>` / `<.select>` migration |
| `lib/phoenix_kit_catalogue/web/catalogues_live.ex` + `catalogue_detail_live.ex` | `unexpected_confirm_event/2` safe fallback (5 delete handlers); structured `log_operation_error/3`; `phx-disable-with` on 9 destructive buttons |
| `test/catalogue_test.exs` | +859 lines. Every smart-catalogue edge case (duplicate detection, self-reference, smart-to-smart, force-delete cascade, nil uuid, rollback-on-invalid, position ordering) |
| `test/support/postgres/migrations/20260420000000_add_v102_smart_catalogues.exs` | **New.** Local test-DB mirror of core V102 — without this the smart-catalogue tests can't hit the real CHECK/UNIQUE constraints |

## PR-Specific Findings

### Solid

1. **`put_catalogue_rules/3` is a proper atomic replace-all** — `Ecto.Multi` composes delete-removed + upsert-kept-or-new inside one transaction (`rules.ex:90-129`). Duplicate detection runs *before* the transaction (`:131-145`), activity log runs *after* it commits — correct ordering given `ActivityLog.log/1` rescues.

2. **`CatalogueRule.effective/2` per-leg inheritance** — value and unit fall back independently from `item.default_value` / `item.default_unit`. Clean semantics: rule-level override wins, item-level default fills in gaps.

3. **Force-delete guard** — `permanently_delete_catalogue/2` returns `{:error, {:referenced_by_smart_items, count}}` when the FK `ON DELETE CASCADE` would silently wipe rule rows. App-layer guard + DB-layer cascade = defense in depth. Tested with self-reference, smart-to-smart, and multi-referencer cases.

4. **`normalize_rule_attrs/1` closed-set normalizer** — drops unknown string keys silently instead of `String.to_existing_atom/1` raising `ArgumentError`. A future caller passing `"foo" => "bar"` gets a clean changeset validation error, not a confusing runtime exception.

5. **`unexpected_confirm_event/2`** — directly closes PR #7 review bug #3. `case socket.assigns.confirm_delete do {"item", uuid} -> …; _ -> unexpected_confirm_event(…) end` replaces `{"item", uuid} = confirm_delete!(socket)` across all 5 delete handlers. Malformed push events now flash + log instead of crashing the LV process.

6. **`log_operation_error/3`** — `Logger.error(fn -> [...] end)` with deferred iodata evaluation, `Ecto.Changeset.traverse_errors` expansion, `actor_uuid` + `entity_type` + `entity_uuid` context. Production incidents diagnosable from the log alone.

7. **Test migration parity** — V102 test mirror uses `add_if_not_exists` + `DO $$ IF NOT EXISTS` CHECK guards. Safely idempotent and matches prod exactly, including the `kind IN ('standard', 'smart')` closed vocab and numeric range checks.

### Minor concerns

1. **`@rule_known_keys` includes `"item_uuid"`** (`rules.ex:185`). In `put_catalogue_rules/3` it's harmless because `rule_attrs_with_item_and_position/3` overwrites it, but `create_catalogue_rule/2` allows a caller to supply `"item_uuid"` via form params. Likely fine for the explicit single-create API, but worth naming.

2. **Unit vocab is open-ended VARCHAR with no DB-level CHECK.** Schema validates against `~w(percent flat) ++ [nil]`, but a direct SQL write could insert `"whatever"`. Moduledoc calls this intentional ("consumers can add new units without a migration"). Defensible tradeoff.

3. **`discount_amount/3` recomputes `sale_price` and `final_price` independently** (`item.ex:249-260`) — three Decimal walks where one with intermediate reuse would do. Not a hot path.

## General Module Review (Elixir / Phoenix / Ecto skill lens)

Skills invoked: `elixir-thinking`, `phoenix-thinking`, `ecto-thinking`.

### Elixir-thinking

- **Iron Law (no process without a runtime reason)** — ✅ No `use GenServer`, `use Agent`, `use Task`, `use Supervisor`, or `use Phoenix.Channel` anywhere in `lib/`. The module is pure data + functions; all concurrency is either Ecto transactions or LV-scoped `start_async`. This is exactly right for a catalogue data module — no process hoarding.
- **No `raise`/`throw`/`exit`** outside comments. Error flow is `{:ok, _} | {:error, _}` throughout. The three raising call sites are narrowly scoped:
  - `fetch_catalogue!/1` / `get_catalogue!/2` / `get_item!/1` — the `!` variants, explicitly documented as raising.
  - `repo().update!/1` inside `Repo.transaction/1` blocks — raises trigger rollback, which is the intended transactional pattern.
- **Pattern matching on function heads** — heavily used (`sale_price(%__MODULE__{base_price: nil}, _)`, `effective_markup/2` split on nullable override, `CatalogueRule.effective/2`). No nested `case` bodies spotted in hot paths.
- **Defaults via `/3` variants** — consistent use of `Keyword.get(opts, :key, default)` rather than `case Keyword.get(…) do nil -> default; v -> v end`. Only composed-over-time cases (`list_catalogues/1` filter chain) use intermediate `case` — appropriate.

### Phoenix-thinking

- **Iron Law (no DB queries in mount/3)** — ✅ Both admin LVs assign empty defaults in `mount/3` and do the real load guarded by `if connected?(socket)`. This is functionally equivalent to "query in `handle_params`" — fires once on websocket connect, never on dead render. A minor aesthetic point: placing the load in `handle_params/3` would be even cleaner for the param-driven LVs, but since neither of these views varies by params beyond the route's single UUID, the current pattern is acceptable.
- **`handle_async` duplicate-name cancellation** — ✅ `catalogues_live.ex:457` + `catalogue_detail_live.ex` both handle the `:exit` branch explicitly, distinguishing cancellations (`:shutdown`, `:killed`, `{:shutdown, _}` → ignored) from real failures (logged + flashed). Directly addresses the phoenix-thinking "later wins" gotcha.
- **PubSub topic** — single `"phoenix_kit_catalogue"` topic broadcast on every write (`pub_sub.ex:20`). Acceptable for a single-tenant library module; if this module is ever reused in a multi-tenant host, topics would need to be scoped by tenant.
- **LiveView `terminate/2`** — not used anywhere (would be silently ignored without `trap_exit`). ✅
- **Upload content-type trust** — `import_live.ex` accepts XLSX/CSV. Parser validates by extension + by XLSX library behavior (magic-byte-aware); the `%Plug.Upload{content_type: …}` field isn't used as a trust boundary. ✅

### Ecto-thinking

- **Cross-context `belongs_to`** — N/A. All schemas live in `PhoenixKitCatalogue.Schemas` and belong to one context.
- **Multiple changesets per schema** — Each schema has a single `changeset/2`. Operations are simple enough that this hasn't caused field-visibility problems (no `registration_changeset` / `admin_changeset` split needed yet). Worth revisiting if e.g. `kind` or `catalogue_uuid` ever becomes something only an admin can change.
- **Preload vs join** — `list_items_for_category_paged/2` and friends use `preload: [:catalogue, :manufacturer]` (separate queries) — correct for has-many where join preloads would duplicate rows. `list_all_categories/0` uses `join: cat in Catalogue` to compose a display name — appropriate for the 1:1 lookup.
- **FK + `ON DELETE`** — `phoenix_kit_cat_item_catalogue_rules` uses `:delete_all` in both directions, combined with the app-layer `:force` guard. Layered defense is correct.
- **CHECK constraints mirror schema validations** — `kind`, `discount_percentage`, `default_value`, rule `value` all have matching DB-level CHECKs. Catches direct-SQL drift.
- **Null-byte sanitization on imports** — user-uploaded file content is parsed by `xlsx_reader` / `nimble_csv`; the resulting strings flow into `Item.changeset/2` and then into Postgres. A `\x00` in a cell would crash the insert. Not observed in practice (XLSX/CSV normally don't carry null bytes), but a `String.replace(&1, "\x00", "")` guard at the import parser boundary would be bulletproof. **Follow-up candidate.**
- **`async: false` in tests** — only `test/import/executor_test.exs` uses it. The executor exercises multi-phase transactions; acceptable reason. All other tests are async.

### Idioms

- Structs over maps for known shapes (`%Catalogue{}`, `%Item{}`, `%CatalogueRule{}`). ✅
- `Helpers.fetch_attr/2` / `has_attr?/2` polymorphic atom/string key accessors — the right call for a module that accepts both IEx-style atom maps and LV form params string maps.
- Gettext for every user-facing string. ✅

## Carryover from PR #7 Review (still present, not regressions)

From `dev_docs/pull_requests/2026/7-catalogue-refactor/AGGREGATED_REVIEW.md`:

1. **`next_category_position/1` called outside the transaction** (`catalogue.ex:952`, `move_category_to_catalogue/3`). Two concurrent moves to the same target catalogue can compute the same `next_pos`. Low-probability but real data-integrity issue under concurrent load.

2. **`move_item_to_category/3` lacks the `FOR SHARE` lock** that `create_item/2` and `update_item/3` have (`catalogue.ex:1525-1554`). `resolve_move_attrs/1` reads the target category without a lock, so it can race a concurrent `move_category_to_catalogue/3` and leave the item with a stale `catalogue_uuid`.

Both flagged in the PR #7 review and not addressed in this PR. Worth a follow-up ticket — neither is a release blocker, but both can corrupt data under concurrent load.

3. **`actor_opts/1` duplicated across 8 LiveViews** — maintenance-only, same 5-line function copy-pasted. Low priority; extract to a shared `PhoenixKitCatalogue.Web.Helpers` when someone has the appetite.

## Precommit & Static Analysis

Ran `mix precommit` (= `format` + `credo --strict` + `dialyzer`) against the merged state (local main at `be25fe9`):

- **format** — ✅
- **credo --strict** — ✅ 862 mods/funs across 57 files, 0 issues
- **dialyzer** — ✅ 0 errors, 0 skipped warnings (1 unnecessary skip in `.dialyzer_ignore.exs`, worth cleaning up separately)

## Verdict

✅ **Approved & merged.** Carefully executed PR: the smart-catalogue feature is orthogonal to the existing pricing model, the context split preserves the full public surface via `defdelegate`, the LV hardening directly closes PR #7 review bug #3, and test coverage is excellent (+859 lines for the rule logic alone). No new bugs introduced. The two carryover concurrency issues from PR #7 remain and should become a separate ticket.

## Release

Version bumped `0.1.9` → `0.1.10` (mix.exs in the PR had `0.1.12` — a 3-version skip with no 0.1.10/0.1.11 published or changelogged; corrected to sequential). CHANGELOG entry covers all of PR #10's surface.
