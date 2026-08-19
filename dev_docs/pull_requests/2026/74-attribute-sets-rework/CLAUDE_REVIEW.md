# PR #74 Review — Attribute sets rework (groups → sets on the entities engine)

**Author**: @mdon (Max Don)
**Reviewer**: Claude (Sonnet 5)
**Status**: Merged, reviewed post-merge
**Merge commit**: `ecbb8b8` (branch tip `f3d9e1b`)
**Date**: 2026-08-19

## What landed

36 files, +10,450/−49. The 2026-08-18 design ([`dev_docs/plans/2026-08-18-attribute-sets-rework.md`](/dev_docs/plans/2026-08-18-attribute-sets-rework.md))
implemented in full: attribute **sets** (one dimension from one vendor —
"Ikea colors") replace the old group→attribute→value hierarchy, stored as
managed `phoenix_kit_entities` blueprints; items attach any number of sets
through a new catalogue-owned join table (`phoenix_kit_cat_item_attribute_sets`,
V177, shipped in core `phoenix_kit` — this repo adds no migration, per its
hard boundary); a write-path contract layer + entities-side delete guard
enforce the blueprint shape; a batched read path resolves per-item sets
without N+1; legacy groups auto-migrate on boot. New context module
`Catalogue.AttributeSets` (~1350 lines), new schema `ItemAttributeSet`, new
LiveView `AttributeSetFormLive` (~1270 lines), substantial rewrites to
`ItemFormLive`, `CataloguesLive`, `CatalogueDetailLive`, `ProductCard`, plus
713 lines of context tests and ~500 more across three new LiveView test
files, and 428 new hand-maintained gettext msgids across all four locale
catalogs.

## Review method

Three parallel deep-dive forks, each scoped to a layer: the core context/data
layer (contract enforcement, activity logging, errors API, query batching),
the LiveView/UI layer (mount hygiene, multilang forms, PubSub scoping,
attach/detach staging), and versioning/gettext/test-coverage/dependencies.
Each cross-checked the shipped code against the design doc's own claims
(never trusting the doc or PR title at face value) and against this repo's
`AGENTS.md` conventions and the `phoenix-thinking`/`ecto-thinking` skills.
Findings were then verified directly against the source before any fix.

## Verified as correct

- **No migration shipped in this repo** — confirmed no `priv/repo/migrations`
  changes; the join table lives in core `phoenix_kit`, matching the hard
  boundary and the design doc's claim.
- **UUID-only join, no cross-module FK** — `ItemAttributeSet` has no FK on
  `set_uuid` (only `foreign_key_constraint(:item_uuid)`), as designed.
- **Deletion guard** is registered as an external `&__MODULE__.fun/1` capture
  (avoiding a stale-closure `:persistent_term` badfun crash after a hot
  code reload) and fails closed on raise/exit; the orphan pruner correctly
  guards on `entities_enabled?()` before treating "not found" as "deleted"
  (avoiding a mass-delete on a disabled-module false read).
- **Activity logging**: every mutating function routes through `tap_log/5`
  or `log_activity/4`, consistent with the repo's actor/audit convention.
- **Context boundary**: `catalogue.ex` `defdelegate`s all 16 new public
  `AttributeSets` functions; no LiveView reaches the submodule directly.
- **Query batching**: `resolve_for_items/2` does 1 attachments query + 1
  `list_values` per *distinct* set UUID, not per item — no N+1, matches the
  design's "7 queries for 50 items / 6 sets" claim.
- **Advisory locking**: `attach_set`/`delete_set` share a per-set
  `pg_advisory_xact_lock`, closing the check-then-act race the design calls
  out.
- **The Iron Law holds** — no DB queries in any new/changed `mount/3` beyond
  the pre-existing pattern already used by every other form LiveView here.
- **`item_form_live.ex`'s multi-set staging is solid** — attach/detach/
  reorder/toggle-selection payloads are validated against
  `available_sets`/`staged_set_uuids`/`set_previews` before acting, saves
  apply atomically, and Cancel abandons staged state cleanly since nothing
  persists until save.
- **`product_card.ex`** correctly loops over N resolved sets (a genuine
  improvement over the old single-group render) and keys off `kind`
  (fixed/multi) per the consumer contract v2 shape.
- **Routing**: `attribute_set_new`/`attribute_set_edit` are registered with
  static segments before the wildcard `:uuid`, per convention; the old
  `attribute_group_form_live.ex` is intentionally kept to redirect stale
  bookmarks, not dead code.
- **Version bump correct**: `mix.exs` `@version` and
  `PhoenixKitCatalogue.version/0` both `"0.16.2"`, consistent.
- **`mix.exs` dependency change is appropriately loose**: `pk_dep(:phoenix_kit_entities, "~> 0.4")`,
  not pinned tighter than needed.
- **Gettext hand-maintenance held**: all four locale files gained the exact
  same 428 msgids (verified by set diff, not just count); sampled et/ru
  translations are real, distinct translations, not copied-English
  placeholders.
- **Test coverage exercises failure paths**, not just happy paths — e.g.
  `{:error, :contract_broken}` assertions and an orphan-pruner cleanup test
  with an activity-log assertion.

## Findings

### BUG-HIGH — stale `mix.lock` made the merged code uncompilable against Hex (fixed)

The catalogue's own code (`attribute_set_form_live.ex`) imports
`PhoenixKitEntities.Components.FieldInput`, a component that does not exist
in `phoenix_kit_entities` 0.4.2 — the version `mix.lock` had pinned. A clean
`mix deps.get` from Hex (no local `PHOENIX_KIT_ENTITIES_PATH` override)
fails to compile on current `main`. `phoenix_kit_entities` 0.4.3, which does
ship `FieldInput`, was already published on Hex.

**Fix applied**: `mix deps.update phoenix_kit_entities` (0.4.2 → 0.4.3),
satisfied by the existing `~> 0.4` constraint — no `mix.exs` change needed.
`mix compile --warnings-as-errors` is clean afterward.

### BUG-MEDIUM — attribute-set mutations never broadcast PubSub; UI goes stale across sessions (fixed)

**File**: `lib/phoenix_kit_catalogue/catalogue/attribute_sets.ex`

Every other context module in this repo (`manufacturers.ex`, `attributes.ex`,
`item_supplier_infos.ex`, `rules.ex`, `suppliers.ex`, `links.ex`,
`pdf_library.ex`) broadcasts `Catalogue.PubSub.broadcast/3` on every
successful write, per the module's own documented convention
("Every successful write in the Catalogue context broadcasts..."). The new
`AttributeSets` module broadcast **nothing** — no set/value/field CRUD, no
attach/detach/reorder, no per-item selection change. `CataloguesLive`'s
`reload_on?(:attribute_groups, kind)` (which now also renders the sets list
when sets are enabled) only matched `[:attribute_group, :item]`; no
`:attribute_set` kind existed at all. Net effect: a second open admin
session — another admin, or the same admin in two tabs — never saw live
updates to set/value/attachment data; only a full navigate/remount picked up
changes.

**Fix applied**:
- Added `:attribute_set` to `Catalogue.PubSub`'s `kind()` type.
- Centralized `PubSub.broadcast(:attribute_set, set_uuid)` inside the
  shared `tap_log/5` helper (covers create/update/delete set, create/update/
  delete value, add/update/remove extra field — all nine call sites use the
  same uuid-of-the-set convention already).
- Added `PubSub.broadcast(:attribute_set, set.uuid)` to `reorder_values/3`
  (which bypasses `tap_log` since it returns bare `:ok`).
- Added `PubSub.broadcast(:item, item_uuid, Helpers.item_catalogue_uuid(item_uuid))`
  to `attach_set/3`, `detach_set/3`, `reorder_attachments/3`, and
  `set_attachment_selection/4` — reusing the existing `:item` kind and the
  existing `Helpers.item_catalogue_uuid/1` lookup, mirroring how the legacy
  `attributes.ex` already broadcasts item-level group-assignment changes.
- `reload_on?(:attribute_groups, kind)` now also matches `:attribute_set`.
- `CatalogueDetailLive` gained a `handle_info` clause for
  `{:catalogue_data_changed, :attribute_set, _uuid, _parent}` — sets are
  global (no catalogue parent), so any open detail page refreshes
  defensively, matching the file's own documented "unknown scope, refresh
  defensively" doctrine for cross-cutting events.

**Tests added**: `test/catalogue/attribute_sets_test.exs` — a new
`"PubSub broadcasts"` describe block asserting `:attribute_set` fires on set
CRUD and `:item` fires (scoped to the item's catalogue) on attach/detach.

### IMPROVEMENT-MEDIUM — `update_set/3` could write a `default_value_slug` with no matching value (fixed)

**File**: `lib/phoenix_kit_catalogue/catalogue/attribute_sets.ex`

The module's own moduledoc and the design doc both state the contract layer
validates "default slug exists among records" on every write, "never a
guessed fallback." The actual `update_set/3` wrote whatever
`default_value_slug` the caller passed straight into
`settings["catalogue"]` with no cross-check against `list_values(set)`. A
stale form resubmit (value deleted in another tab), or any future non-UI
caller, would silently persist a ghost default; `resolve_set/2` would then
hand every consumer (product card, order-line resolution) a `default` slug
matching no real value — exactly the guessed-fallback failure mode the
contract doctrine exists to prevent.

**Fix applied**: added `validate_default_slug/2` (mirroring the existing
`validate_kind/1` pattern) — `nil` is always valid (no default is a
legitimate state), any other slug must match a current value's `slug` or the
write is refused with `{:error, :contract_broken}`. Wired into `update_set/3`'s
`with` chain before the write.

**Test added**: `test/catalogue/attribute_sets_test.exs` —
"update_set refuses a default_value_slug with no matching value — never a
guessed default", asserting both the refusal and that the set's contract
still resolves `default: nil` afterward (not silently dropped, not
half-written).

### IMPROVEMENT-MEDIUM — 12 new error atoms had no `Errors.message/1` clause or test pin (fixed)

**File**: `lib/phoenix_kit_catalogue/errors.ex`

`AGENTS.md`: "A new error atom requires a `message/1` clause plus a pin in
`test/errors_test.exs`." `attribute_sets.ex` introduces `:contract_broken`,
`:entities_disabled`, `:invalid_kind`, `:set_not_found`, `:set_in_use`,
`:not_attached`, `:label_required`, `:invalid_type`, `:options_required`,
`:duplicate_key`, `:unknown_field`, `:invalid_value` — none had a central
`message/1` clause. Not a live UX bug today (the two LiveViews that surface
these atoms — `catalogues_live.ex` for `:set_in_use`, `attribute_set_form_live.ex`
for the field-editor atoms — already handle them with local, hardcoded flash
text, and fall back to a generic message for the rest), but it's drift
against a convention this repo enforces everywhere else, and a future caller
routing any of these through the central `Errors.message/1` would leak a raw
atom via the catch-all.

**Fix applied**: added all 12 atoms to `error_atom()` and 12 `message/1`
clauses, gettext-wrapped per the module's own convention. Five of the twelve
(`:set_not_found`, `:set_in_use`, `:label_required`, `:options_required`,
`:duplicate_key`) reuse strings already hand-added to all four gettext
catalogs by this same PR (verified against `priv/gettext/*/default.po`), so
they already have real et/ru translations. The remaining seven were new
strings — added to `default.pot` and all three locale `.po` files by hand
(short, unambiguous admin-UI strings; real et/ru translations written, not
copied placeholders), per `AGENTS.md`'s hand-maintenance requirement for
this backend.

**Tests added**: 12 new cases in `test/errors_test.exs`; a new
`"attribute-sets strings are translated"` pin in `test/gettext_test.exs`
(ru + et) following the existing PDF-search pin's pattern.

### NITPICK — `reorder_values` LiveView handler swallowed write failures (fixed)

**File**: `lib/phoenix_kit_catalogue/web/attribute_set_form_live.ex`

`handle_event("reorder_values", ...)` called
`Catalogue.reorder_attribute_set_values/3` and ignored the return, always
reloading — every sibling handler in the same file (add/rename/delete value,
extras, field editor) pattern-matches `{:ok, _}`/`{:error, _}` and flashes on
failure via the file's own `save_failed_flash/1` helper. A failed reorder
write (e.g. `:entities_disabled`) would silently snap back to the stored
order with no error shown.

**Fix applied**: pattern-match the result; on `{:error, _}`, flash via the
existing `save_failed_flash/1` (matching the file's established style) before
reloading.

### IMPROVEMENT-MEDIUM (informational, not changed) — no multilang UI for set/value names

`AttributeSetFormLive` drops the old `AttributeGroupFormLive`'s
`MultilangForm`/AI-translate integration entirely — no `@translatable_fields`,
no language tabs. The moduledoc explicitly notes this is deferred
("translations ride entities' own multilang mechanisms — follow-up"), and
the design doc lists `settings.translations` as the intended future
mechanism. Not a regression to fix here — it's a scoped, documented
follow-up, not a defect this review should patch (implementing multilang
UI on top of the entities blueprint's own translation storage is
architecture work belonging to a dedicated PR, not a review fix-up). Flagging
so it stays visible: multi-language catalogues currently can't translate set
or value display names through this UI until that follow-up ships.

### PROCESS (informational, not changed) — unrelated triage docs bundled into this PR

PR #74 also carries `dev_docs/pull_requests/2026/{61,66,67,69,70}-*/FOLLOW_UP.md`
— follow-up docs for *other*, unrelated PRs. These are legitimate,
non-conflicting content (consistent with this repo's own git log, commit
`12f3087` "Triage PR reviews #61/#66/#67/#69/#70"), not accidental inclusion
or scope creep with any functional effect. Left as-is; noting only because
bundling unrelated doc updates into a large feature PR makes the diff
harder to review in isolation next time.

## Gate

- `mix format` — clean.
- `mix precommit` (format --check-formatted, `credo --strict`, dialyzer) —
  **clean after fixes**. Pre-existing-from-this-PR credo findings resolved
  along the way (not newly introduced by this review, but blocking a clean
  gate): two "nested modules could be aliased" in test setup blocks
  (`item_form_sets_test.exs`, `attribute_sets_surfaces_test.exs`,
  `attribute_set_form_live_test.exs` — added the missing
  `alias PhoenixKitCatalogue.Catalogue.AttributeSets`) and two
  "function body nested too deep" refactors (`AttributeSets.attach_set/3`
  extracted into `handle_attach_result/4`; `ItemFormLive.value_thumb/2`'s
  inner `if` extracted into `valid_thumb_uuid/1`) — pure structural
  extractions, no behavior change (covered by existing tests).
- `mix test` — 2 doctests, 1648 tests, 0 failures on a clean run. One
  **pre-existing, unrelated flake** observed intermittently in
  `test/item_supplier_infos_test.exs` ("history_for_pair/2 returns all rows
  for a pair ordered newest-first") — reproduces on `main` independent of
  this PR or this review's changes (timestamp-ordering race, nothing to do
  with attribute sets); out of scope for this review, not fixed here.

## Related PRs

- Previous: [#73](/dev_docs/pull_requests/2026/73-view-toggle-toolbar)
