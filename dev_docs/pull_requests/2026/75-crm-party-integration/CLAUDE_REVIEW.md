# PR #75 Review — Suppliers and manufacturers become CRM parties

**Author**: @mdon (branch `feat/crm-party-integration`)
**Reviewer**: Claude (Sonnet 5)
**Status**: Merged, reviewed post-merge
**Merge commit**: `1676d25` (branch tip `346a646`)
**Date**: 2026-08-21

## What landed

42 files, +6,399/−1,852. Two design docs implemented:
[`2026-08-20-crm-party-bridge.md`](/dev_docs/design/2026-08-20-crm-party-bridge.md)
and [`2026-08-21-supplier-custom-fields.md`](/dev_docs/design/2026-08-21-supplier-custom-fields.md).
Manufacturers and suppliers can now resolve *through* to a party in the
optional `phoenix_kit_crm` sibling module (new `Catalogue.CrmLink`, ~421
lines; `crm_company_uuid` column on both schemas), with local rows staying
the fallback when CRM is absent or a row isn't linked. The standalone
`ManufacturerFormLive` / `SupplierFormLive` LiveViews and their CRUD tabs on
`CataloguesLive` are deleted outright — manufacturer/supplier identity is now
either CRM-owned or resolved inline wherever it's needed, with no dedicated
admin page. A large `item_form_live.ex` rewrite (2,299 lines changed) adds
CRM-aware supplier attach/detach and a (currently flag-disabled) supplier
custom-fields editor backed by a new `Catalogue.SupplierFields` context
(~553 lines) built on `phoenix_kit_entities` blueprints. `import/executor.ex`
gained batched party resolution so CSV/XLSX/Pro100 imports link suppliers
without a per-row CRM round trip. 519 lines of new CRM-link tests, 244 lines
of new supplier-fields tests, 333 lines of new item-form tests, plus 908
new/changed gettext msgids kept in sync across en/et/ru.

## Review method

Four parallel deep-dive forks, each scoped to a layer: the CRM link/party
core (`crm_link.ex`, `manufacturers.ex`, `suppliers.ex`, schemas), the
supplier custom-fields feature (`supplier_fields.ex`,
`item_supplier_infos.ex`), `item_form_live.ex` + `components.ex`, and the
remaining surface area (deleted LiveViews, `import/executor.ex`,
`catalogues_live.ex`, test router, gettext sync). Each cross-checked the
shipped code against the design docs' own claims, against this repo's
`AGENTS.md` conventions, against core `phoenix_kit`'s actual migrations
(not just the schema code's assumptions), and against the
`phoenix-thinking`/`ecto-thinking` skills. Findings were verified directly
against the source before any fix.

## Verified as correct

- **Migration cross-check passed** — `crm_company_uuid`,
  `manufacturer_source`, `manufacturer_name_snapshot`, and the
  `phoenix_kit_cat_item_supplier_info_current_pair_uniq` partial unique index
  all exist in core `phoenix_kit`'s V178–V180 exactly as this repo's code
  assumes. The "PR #44 shipped a migration missing columns the schema
  needed" drift pattern did **not** recur here.
- **`crm_link.ex` linking/unlinking is transactional and race-safe** —
  optimistic-concurrency `update_all` guards, grant-then-stamp atomicity, and
  every one of a documented prior review round's defects (partial grant,
  `list_all/1` hiding rows, stale writes, picker shape mismatch) are fixed in
  the shipped code, not just claimed fixed.
- **`crm_company_uuid` is excluded from both schemas' `@optional_fields`** —
  the manufacturer/supplier edit form changeset cannot write party identity
  out from under a link.
- **Hard-delete stays safe** — `crm_company_uuid` is a plain column on the
  deleted row, not a join-table xref, so hard-deleting a manufacturer/supplier
  leaves no orphan link record; `delete_with_links/1` transactions the M:N
  `Links` cleanup against the delete as before.
- **Soft-reference discipline holds in the custom-fields feature** —
  `SupplierFields.values/1`/`value/2` operate purely on the passed struct's
  own `metadata`; no code assumes a hard FK from `item_supplier_info.supplier_uuid`
  into a local suppliers table.
- **Custom-field values are validated, not trusted** — `cast_values/2` routes
  through `PhoenixKitEntities.FormBuilder.cast_field/2` and returns
  `{:error, :invalid_value}` / `{:error, :unknown_field}` rather than
  persisting garbage; nothing calls `put_values/2` with raw input.
- **No N+1 on custom fields** — values live in one already-loaded JSONB
  column; rendering N supplier rows costs zero extra queries.
- **The Iron Law holds** — `item_form_live.ex` does all its loading
  (including the new CRM/supplier-info work) inside `mount/3` via helper
  functions, which is this LiveView's pre-existing pattern from before the
  PR, not a regression it introduced.
- **CRM-resolved names are nil-safe in the UI** — `supplier_display_name/2`
  falls back to the stored `supplier_name_snapshot`/uuid, and
  `components.ex`'s `manufacturer_display/1` renders `"—"` rather than
  crashing when a lookup hasn't resolved or failed.
- **Import batches party resolution** — `resolve_parties`/
  `create_manufacturers_lookup`/`create_suppliers` build one name→uuid map
  per import run before the item loop; no per-row CRM call. Per-item
  supplier-attach failures degrade per-row (logged, item already inserted)
  rather than aborting the whole batch.
- **Gettext stayed in sync** — `default.pot` and all three `.po` files carry
  exactly 908 msgids each.
- **Custom-fields tests assert error paths**, not just happy paths —
  `:label_required`, `:invalid_type`, `:duplicate_key`, `:options_required`,
  `:unknown_field`, `:invalid_value`, `:entities_disabled` are all exercised
  for every mutating op, including the "rejected request doesn't leave a
  provisioned blueprint" side-effect guarantee.

## Findings

### BUG-HIGH — CRM soft-dependency calls in `manufacturers.ex`/`suppliers.ex` could crash item listing pages (fixed)

**Files**: `lib/phoenix_kit_catalogue/catalogue/manufacturers.ex`,
`lib/phoenix_kit_catalogue/catalogue/suppliers.ex`

`crm_link.ex`'s moduledoc is explicit that CRM calls "cannot raise out of
this module" and every one of its `apply(PhoenixKitCRM..., ...)` call sites
is wrapped in `rescue`/`catch`. The twin CRM helpers in `manufacturers.ex`
(`batch_resolve_crm/1`, `try_resolve_crm/1`, `list_crm_manufacturers/0`) and
`suppliers.ex` (`batch_resolve_crm/1`, `try_resolve_crm/1`,
`list_crm_companies/0`, `list_crm_contacts/0`) had no such guard — only a
`function_exported?`/`Code.ensure_loaded?` presence check, which says
nothing about whether the call *succeeds*. These functions back `hydrate/1`
and `resolve_many/1`, which are on the item-listing hot path (`search.ex`,
several `catalogue.ex` query helpers, `Suppliers.items_supplied_by/1`) — a
transient failure on the CRM side (bad data, API drift, a DB hiccup in the
sibling module) would crash catalogue page rendering entirely instead of
falling back to local data the way the "soft dependency" design intends.
Nothing in the test suite would have caught this: `PhoenixKitCRM` isn't
loaded at all in this repo's tests, so every `crm_link_test.exs` case only
exercises the CRM-absent branch.

**Fix applied**: added matching `rescue`/`catch` clauses to all six helper
functions, returning the same safe fallback (`%{}`, `:error`, or `[]`) the
CRM-absent branch already returns — mirroring `crm_link.ex`'s pattern
exactly.

### IMPROVEMENT-MEDIUM — `:already_linked` error atom had no `Errors.message/1` clause or test pin (fixed)

**File**: `lib/phoenix_kit_catalogue/errors.ex`

`AGENTS.md`: "A new error atom requires a `message/1` clause plus a pin in
`test/errors_test.exs`." `ItemSupplierInfos.create/2` and
`import/executor.ex` both return `{:error, :already_linked}`, but the atom
had no central `message/1` clause — unlike its siblings
`:entities_disabled`/`:unknown_field`. `item_form_live.ex` happens to handle
it via a local `supplier_error_message/1` today, so nothing broke yet, but
`Errors.message/1` has no catch-all clause: any future caller routing this
reason through the shared module instead would hit a `FunctionClauseError`.

**Fix applied**: added `message(:already_linked)` to `Errors` (same wording
as the existing local `item_form_live.ex` copy) and a pinning test in
`test/errors_test.exs`.

### BUG-HIGH — stale test-router routes to deleted `ManufacturerFormLive` and removed `CataloguesLive` actions (fixed)

**File**: `test/support/test_router.ex`

The PR deletes `manufacturer_form_live.ex` and `supplier_form_live.ex`, and
removes the `:manufacturers`/`:suppliers` action clauses from
`CataloguesLive` entirely. The router's `SupplierFormLive` routes were
correctly deleted in the same diff hunk, but the `ManufacturerFormLive` pair
(`/manufacturers/new`, `/manufacturers/:uuid/edit`) was missed, and the
`live("/manufacturers", CataloguesLive, :manufacturers)` /
`live("/suppliers", CataloguesLive, :suppliers)` routes were left pointing
at action atoms `CataloguesLive` no longer handles.
`MIX_ENV=test mix compile` confirms the dangling reference:
`warning: PhoenixKitCatalogue.Web.ManufacturerFormLive.__live__/0 is
undefined`. No test currently navigates to these paths, so this was a latent
trap rather than an active failure — but a router pointing at nonexistent
modules/actions is exactly the kind of drift that breaks the next person to
touch this file.

**Fix applied**: removed both `ManufacturerFormLive` routes and the stale
`:manufacturers`/`:suppliers` `CataloguesLive` routes from
`test/support/test_router.ex`.

### NITPICK — two dead empty `describe` blocks left after coverage was removed (fixed)

**Files**: `test/web/form_lv_branches_extras_test.exs`,
`test/web/catalogues_live_test.exs`

Deleting `toggle_manufacturer`/`toggle_supplier` and manufacturer/supplier
deletion tests (correctly, since the code they covered is gone) left two
empty `describe "..." do end` blocks and a stale moduledoc reference behind.
An empty describe reads as a TODO and gives false confidence that something
is still pinned there.

**Fix applied**: removed both empty blocks and updated
`form_lv_branches_extras_test.exs`'s moduledoc to drop the reference to the
removed toggle tests.

## Noted, not fixed

### IMPROVEMENT-MEDIUM — `SupplierFields.add_field/2` has a non-atomic duplicate-key race

**File**: `lib/phoenix_kit_catalogue/catalogue/supplier_fields.ex`

`add_field/2`'s duplicate-key check re-fetches the field-definition blueprint
and validates uniqueness before writing, but the read-modify-write on the
blueprint's field list isn't wrapped in a transaction or advisory lock — two
concurrent `add_field` calls adding the same label could both pass the
uniqueness check before either writes. Left unfixed: this is an admin-only,
single-install action, and the entire supplier custom-fields feature ships
**flag-disabled** in this PR (`@supplier_custom_fields`/
`@supplier_terms_fields` are compile-time `false` in `item_form_live.ex` at
the owner's request — the UI doesn't render it and handlers no-op). Worth an
advisory lock (mirroring `attribute_sets.ex`'s `attach_set`/`delete_set`
pattern from PR #74) if and when the feature is turned on for real use, but
adding transactional locking now, for a UI nobody can reach, is
speculative hardening ahead of need.

## Related PRs

- Related: [#44](/dev_docs/pull_requests/2026/44-parties-supplier-info) —
  original supplier-info groundwork this PR builds the CRM bridge on top of.
- Pattern precedent: [#74](/dev_docs/pull_requests/2026/74-attribute-sets-rework) —
  advisory-locking pattern referenced above; also the last PR with a similar
  "missing `Errors.message/1` clause" finding.
