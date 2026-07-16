# Review — PR #44: Supplier×item info layer (junction context, resolver facade, item-form suppliers card)

Merged as `1ccde09` (fork sync from `timujinne/feature/parties-supplier-info`,
commits `29bf82a` + `fa514b1`). Reviewed against the Ecto and Phoenix
thinking skills, cross-checked against the PR's own ADR
(`dev_docs/adr/0001-cross-module-references.md`) and against the sibling
`../phoenix_kit` and `../phoenix_kit_crm` checkouts this PR's code depends on
at runtime.

**Overall:** the design is sound — soft UUID + source tag + name snapshot for
a cross-module reference is the right call, the ADR captures it well, and the
`set_primary` transaction/force_change handling (from the PR's own
`fa514b1` review-fix commit) is careful, correct code. The problems below are
two kinds: one is a genuine cross-repo release gap that makes the shipped
feature non-functional, the rest are catalogue-side bugs where the code's
CRM-integration half silently never fires, plus a type-contract gap dialyzer
caught once actually run against this code. Findings 2–6 are fixed in this
pass with tests (and a from-scratch clean `mix dialyzer`); finding 1 is a
hard blocker documented here per the maintainer's direction — no phoenix_kit
changes were made this pass.

---

## 1. `phoenix_kit_cat_item_supplier_info` is missing columns the new schema requires — every save crashes — **critical, not fixed (cross-repo)**

`Schemas.ItemSupplierInfo` (added by this PR) declares and requires
`supplier_source`, and reads/writes `is_primary` via a named partial unique
index:

```elixir
@required_fields [:item_uuid, :supplier_uuid, :supplier_source]
...
|> unique_constraint(:item_uuid,
     name: :phoenix_kit_cat_item_supplier_info_primary_uniq,
     message: "another supplier is already marked primary for this item"
   )
```

Per this module's own convention ("No DB migrations of its own... adding a
column means a phoenix_kit core migration first"), the table itself comes
from `../phoenix_kit`'s `V149` migration (`Add V149 migration: catalogue
item-supplier sourcing info + CRM xref`, commit `d82667ee`, same day as this
PR). Its `CREATE TABLE` is:

```sql
CREATE TABLE IF NOT EXISTS phoenix_kit_cat_item_supplier_info (
  uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
  item_uuid UUID NOT NULL REFERENCES phoenix_kit_cat_items(uuid) ON DELETE CASCADE,
  supplier_uuid UUID NOT NULL,
  supplier_sku VARCHAR(100),
  supplier_name_snapshot VARCHAR(255),
  unit_cost NUMERIC(14,4),
  currency VARCHAR(3),
  lead_time_days INTEGER,
  min_order_qty NUMERIC(14,4),
  valid_from DATE,
  valid_to DATE,
  position INTEGER NOT NULL DEFAULT 0,
  metadata JSONB NOT NULL DEFAULT '{}',
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
)
```

No `supplier_source`, no `is_primary`, no partial unique index. Every
`ItemSupplierInfos.create/2` (i.e. every "Add Supplier" click in the new
`ItemFormLive` card) issues an `INSERT` naming a `supplier_source` column
that doesn't exist — Postgres returns `42703 undefined_column` and the save
fails. `set_primary/2` hits the same wall on `is_primary`. **The entire
feature is non-functional as merged.**

This is not a stale-checkout artifact — checked against the current
`../phoenix_kit` state at review time:

- `mix.lock` in this repo pins `phoenix_kit` to `1.7.194` (`:hex` source).
- The sibling `../phoenix_kit` checkout is at `1.7.196`, and `V149`'s content
  is unchanged since `d82667ee` — `git log --oneline -- .../v149.ex` shows
  one commit. `@current_version` is still `150`; neither the `1.7.195` nor
  `1.7.196` bump added a follow-up migration.
- `grep -rn "supplier_source\|is_primary" .../v149.ex` — zero matches.

**Why this wasn't caught:** `test/item_supplier_infos_test.exs` (added by
this PR) is a `DataCase` integration test that would exercise exactly this
path, but this sandbox — like whatever environment the PR was authored and
merged in — has no local Postgres, so `test_helper.exs` excludes
`:integration` tests rather than failing. The gap shipped invisibly.

**Fix (not applied — out of this repo's scope, per maintainer direction):**
a new additive migration in `../phoenix_kit` (`V151`, since `V149`/`V150` are
already published and tags are immutable) adding:

```sql
ALTER TABLE phoenix_kit_cat_item_supplier_info
  ADD COLUMN IF NOT EXISTS supplier_source VARCHAR(20) NOT NULL DEFAULT 'local',
  ADD COLUMN IF NOT EXISTS is_primary BOOLEAN NOT NULL DEFAULT false;

CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_cat_item_supplier_info_primary_uniq
  ON phoenix_kit_cat_item_supplier_info (item_uuid)
  WHERE is_primary = true;
```

Until that ships (and this repo's `mix.lock` is bumped to depend on it), the
Suppliers card should be treated as **disabled in production** — see the
CHANGELOG entry for this release, which flags it as a known blocker rather
than shipping it as advertised.

---

## 2. `Suppliers.list_all/1` never returns CRM suppliers — `PartyRoles.list_suppliers/0` doesn't exist — **high, fixed**

```elixir
defp list_crm_suppliers do
  if crm_available?() and function_exported?(PhoenixKitCRM.PartyRoles, :list_suppliers, 0) do
    apply(PhoenixKitCRM.PartyRoles, :list_suppliers, [])
    ...
```

`../phoenix_kit_crm/lib/phoenix_kit_crm/party_roles.ex` has no
`list_suppliers/0` — its public surface is `get_supplier/1`,
`list_companies_with_role/2`, `list_contacts_with_role/2`, and role-management
functions. `function_exported?/3` correctly evaluates to `false`, so
`list_crm_suppliers/0` silently and permanently returns `[]`. `Suppliers.list_all/1`
backs the `all_suppliers` assign that populates the item form's supplier
picker dropdown (`ItemFormLive` line ~152) — so even with finding 1 fixed,
CRM parties would never appear as pickable suppliers, contradicting the
module's own moduledoc ("CRM suppliers are listed first (when available)").
Untested: the PR's CRM-path tests only cover the "CRM absent" branch, so a
`function_exported?` check against a function that doesn't exist anywhere in
CRM read as equivalent to "CRM absent" and passed.

**Fix applied** — rewrote `list_crm_suppliers/0` to call
`list_companies_with_role("supplier", [])` and
`list_contacts_with_role("supplier", [])`, both of which exist and are the
correct source-of-truth (role-scoped queries, not a listing function CRM
never shipped). This also lets each entry carry the *specific*
`:crm_company` / `:crm_contact` tag directly from the call site instead of
guessing (see finding 3). Added
`test/support/fake_crm_party_roles.ex` — a minimal `PhoenixKitCRM.PartyRoles`
stand-in compiled only under `MIX_ENV=test` (this repo has no dependency on
`phoenix_kit_crm`) so the guard's "CRM present" branch has something real to
exercise — plus new cases in `Suppliers.list_all/0` tests
(`item_supplier_infos_test.exs`) asserting CRM entries appear and are tagged
correctly.

---

## 3. CRM contacts are always mislabeled `:crm_company` — the source discriminator never discriminates — **medium, fixed**

```elixir
defp crm_party_source(party) do
  cond do
    Map.has_key?(party, :company_uuid) -> :crm_contact
    true -> :crm_company
  end
end
```

`PartyRoles.get_supplier/1` (the function this was meant to classify) always
returns `%{uuid, name, email, phone, website, source: :crm}` — for **both**
companies and contacts (see `hydrate_company_supplier/1` and
`hydrate_contact_supplier/1` in `party_roles.ex`); neither ever includes a
`:company_uuid` key. So `Map.has_key?(party, :company_uuid)` is always
`false`, and every CRM party resolved through this path was tagged
`:crm_company` regardless of its real type. The PR's own review-fix commit
(`fa514b1`) added the comment "a CRM party stored as local would misroute the
resolver and the audit task" for the *local-vs-CRM* case but missed that the
*company-vs-contact* half of the same tag had the identical bug baked in from
the start.

Practical impact was masked by finding 2 (the mislabeled path was
unreachable via the UI dropdown until `list_all/1` actually returned CRM
entries), but `Suppliers.resolve/1` — a public, documented facade function —
had the same bug live for any caller.

**Fix applied** — `list_crm_suppliers/0`'s replacement (finding 2) tags
`:crm_company` / `:crm_contact` directly at the call site (it already knows
which role-listing function produced each entry, no guessing needed).
`try_resolve_crm/1` (backing `resolve/1`) now passes through `party.source`
(`:crm`) instead of fabricating a specific-but-wrong tag; `resolve/1`'s
`@doc` was updated to say `:crm | :local` and explain why it's less specific
than `list_all/1`'s per-type tags (`get_supplier/1` federates both roleable
types in one call without exposing which one it hydrated). Added a
`resolve/1` — CRM present" test case confirming the `:crm` tag.

---

## 4. New supplier-info mutations never pass `actor_opts(socket)` — activity log rows have `actor_uuid: nil` — **medium, fixed**

Every other mutating call in `ItemFormLive` threads `actor_opts(socket)`
(`Catalogue.create_item(params, actor_opts(socket))`,
`Catalogue.update_item(..., actor_opts(socket))`,
`Catalogue.put_catalogue_rules(item, rules, actor_opts(socket))`, etc.) — the
three new handlers didn't:

```elixir
case ItemSupplierInfos.create(attrs) do          # save_supplier_info
case ItemSupplierInfos.set_primary(info) do      # set_primary_supplier
case ItemSupplierInfos.delete(info) do           # delete_supplier_info
```

`opts[:actor_uuid]` defaults to `nil`, so every `item_supplier_info.created` /
`.primary_set` / `.deleted` activity row is attributed to no one — breaking
the audit-trail convention AGENTS.md documents ("`actor_uuid` is asserted on
every row" via `activity_logging_test.exs`). That pin test wasn't extended to
cover the three new action atoms, so nothing caught the gap.

**Fix applied** — all three handlers now pass `actor_opts(socket)`. Added a
`ItemFormLiveTest` case (`"supplier info card"`) that logs in via
`build_admin_scope/0` + `with_scope/2`, drives `open_add_supplier` →
`supplier_info_field_change` → `save_supplier_info` through
`Phoenix.LiveViewTest`, and asserts `assert_activity_logged(...,
actor_uuid: scope.user.uuid)`.

---

## 5. New context functions bypass the `Catalogue` facade the module documents as its public surface — **medium, fixed**

`Suppliers`' own moduledoc states "Public surface is re-exported from
`PhoenixKitCatalogue.Catalogue`" — true for every pre-existing function, but
this PR added `resolve/1`, `list_all/1` to `Suppliers` and the entire
`ItemSupplierInfos` context (list_for_item/1, get/1, create/2, update/3,
delete/2, set_primary/2, primary_for_item/1) with **no** `defdelegate` in
`catalogue.ex`. `ItemFormLive` calls both context modules directly instead
(`alias PhoenixKitCatalogue.Catalogue.ItemSupplierInfos` /
`.Suppliers`), which works from inside the LiveView but breaks the
documented "one-stop `Catalogue` API" pattern every other context in this
module follows, and the moduledoc's claim was simply no longer true for the
new functions. Programmatic/IEx callers using the documented facade (AGENTS.md
explicitly calls this out as a supported pattern) had no way to reach the new
feature.

**Fix applied** — added `defdelegate`s in `catalogue.ex`:
`resolve_supplier/1`, `list_all_suppliers/1`,
`list_supplier_infos_for_item/1`, `get_supplier_info/1`,
`create_supplier_info/2`, `update_supplier_info/3`, `delete_supplier_info/2`,
`set_primary_supplier_info/2`, `primary_supplier_info_for_item/1`. Renamed
relative to the context functions (`resolve_supplier` not `resolve`,
`list_all_suppliers` not `list_all`, etc.) — the bare names are too generic
for a facade with dozens of other resources and risk future collisions.

---

## 6. `Catalogue.PubSub`'s `kind()` typespec was never extended for the new broadcast — **low, fixed**

Every mutating `ItemSupplierInfos` function broadcasts
`PubSub.broadcast(:item_supplier_info, uuid)`, but `PubSub.@type kind()` is a
closed union that didn't include `:item_supplier_info` — this repo's own
documented convention for adding a broadcast kind (see AGENTS.md's PDF
section: "`:pdf` is added to the `kind` typespec in `Catalogue.PubSub`") was
skipped for this PR. No runtime crash results — every `handle_info({:catalogue_data_changed,
kind, ...}, socket)` clause in this codebase matches `kind` unbound or with
`_kind`, never an exhaustive atom `case`, so the out-of-contract atom just
flows through as a no-op for LiveViews that don't care about it. But it broke
the type contract: `mix dialyzer` flagged all four `broadcast(:item_supplier_info,
...)` call sites as "will never return" (since their first argument doesn't
match `kind()`'s success typing), which cascaded into three more false
"pattern can never match `{:ok, _}`" warnings at the `ItemFormLive` call
sites — dialyzer concluded the success branch of `create/2` / `set_primary/2`
/ `delete/2` was dead code, since it always routes through the "impossible"
broadcast call before returning `{:ok, _}`. Fully explains 7 of this PR's 8
dialyzer warnings from one root cause.

**Fix applied** — added `:item_supplier_info` to `PubSub.@type kind()`.
Re-running `mix dialyzer` after the fix drops from 8 raw warnings to a clean
pass. The remaining warning (`item_supplier_infos.ex:140`,
`Ecto.Multi.update_all/3` inside `set_primary/2`) is an unrelated, well-known
Ecto+dialyzer opaque-type false positive — same category as the pre-existing
`gettext.ex` entry already in `.dialyzer_ignore.exs`; added a matching entry
rather than restructuring working code to dodge a tooling limitation. Also
added ignore entries for the new `audit_supplier_refs.ex` Mix task's
`Mix.Task`/`Mix.shell()` calls — the `:mix` application isn't in the dialyzer
PLT, so any Mix.Task module reads as calling unknown functions; this is
inherent to dialyzing a Mix.Task, not a code issue (this repo just never had
a second Mix.Task before this PR to surface it).

---

## Noted but not fixed

- **Orphaned `Item.primary_supplier_uuid` column.** This PR removes the
  `belongs_to :primary_supplier` association, its cast field, and its
  `foreign_key_constraint` from `Schemas.Item` — a deliberate replacement of
  the V146 scalar-FK approach with the new junction table's `is_primary` flag
  (confirmed intentional via commit `29bf82a`'s message). The DB column and
  its hard FK to `phoenix_kit_cat_suppliers` (added by core `V146`) still
  exist and are simply unreferenced by the schema now. Not a bug, but
  undocumented in the ADR and has no follow-up migration to drop it — flagged
  for awareness, not worth a migration on its own until `V151` (finding 1) is
  written anyway.
- **`ItemSupplierInfos.create/2`'s auto-promote-to-primary check** runs
  `primary_for_item/1` as a separate query *after* the insert commits, not
  inside a transaction with it. Two concurrent first-time "Add Supplier"
  calls on the same item could both see "no primary yet" and both attempt
  `set_primary/2`; the partial unique index correctly prevents a double-primary,
  but the loser's `create/2` call would return `{:error, reason}` even though
  its row *was* inserted (just non-primary) — the LiveView would show "Failed
  to add supplier" for a save that actually succeeded. Low-probability
  (single-operator admin UI, not a public-traffic endpoint) — not fixed.

## Verified correct

- `ItemSupplierInfo.changeset/2`'s `validate_date_range/1` and
  `validate_currency/1` — correct, straightforward.
- `ItemSupplierInfos.set_primary/2`'s `force_change` + re-attached
  `unique_constraint` (from the PR's own `fa514b1` fix) — correct: without
  `force_change`, promoting an already-in-memory-primary struct diffs to an
  empty changeset and skips the `UPDATE`, stranding the item with no primary
  after `clear_primary` demotes the DB row. Traced through by hand; the fix
  is exactly right.
- `ItemSupplierInfo` schema's `supplier_uuid` deliberately has no
  `foreign_key_constraint` (soft cross-module ref, matches the ADR) — correct
  per the module's own stated design, not an oversight.
- `blank_to_unnamed/1` fallback naming (added in this review's fix) mirrors
  `PhoenixKitCRM.Schemas.Company.display_name/1` /
  `Contact.display_name/1`'s fallback behavior without a hard compile-time
  dependency on those modules.

## Verification

`mix format` clean. `mix compile --warnings-as-errors` clean. `mix credo
--strict`: 6 Refactor-level suggestions, all pre-existing patterns —
2 are new instances of "avoid apply/2 and apply/3" on this review's
`list_crm_companies/0` / `list_crm_contacts/0`, matching the same
already-accepted `apply/3`-behind-`function_exported?` soft-dependency style
already used one function above them (`try_resolve_crm/1`, present before
this review) and documented in this PR's own commit message ("CRM calls via
apply/3 to avoid compile warnings"); the other 4 (nesting depth, cyclomatic
complexity, one more `apply/3`) are entirely inside
`lib/mix/tasks/phoenix_kit_catalogue.audit_supplier_refs.ex`, untouched by
this review. `mix dialyzer` was not clean before this pass — see finding 6 —
and is now a full clean pass (`Total errors: 8, Skipped: 8, Unnecessary
Skips: 0`, `done (passed successfully)`) after the `PubSub.kind()` fix and
two new `.dialyzer_ignore.exs` entries for known Ecto/Mix.Task false
positives. `mix test` could not run in this sandbox — `test_helper.exs`
shells out to `psql` to probe for a local Postgres and it isn't installed
here, so `:integration` tests are excluded (this is the same condition that
let finding 1 ship unnoticed). New/updated tests were reviewed by manual
trace against the fixtures and the actual `phoenix_kit_crm` source; they
should be run for real in CI or a Postgres-equipped environment before this
is considered fully verified.
