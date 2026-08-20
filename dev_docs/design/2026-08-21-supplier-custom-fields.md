# Supplier rows: entities-defined custom fields

**Date:** 2026-08-21
**Status:** built and deployed to max-dev, then **HIDDEN the same day** at the
owner's request ("simplify things — remove the entity stuff from suppliers,
leave it for when he wants it back"). Not released.
**Direction:** boss — "for these types of data we should be using entities like
we already did in the modules", plus "the add supplier drawer isn't very good,
it should be a popup"

---

## Current state: hidden behind one flag

`PhoenixKitCatalogue.Web.ItemFormLive`'s `@supplier_custom_fields false` is the
whole switch. With it off:

- the **Fields** button does not render, and `open_supplier_field_manager`
  no-ops server-side so a crafted event cannot open it either;
- `load_supplier_fields/0` returns `[]`, which empties the per-field columns on
  the suppliers table and the Extra fields block in the supplier modal without a
  branch at each site;
- rows written while hidden get **no** `custom_fields` key at all
  (`put_values/2` treats an empty merge as a no-op);
- values written **before** it was hidden are preserved through edits — the edit
  path merges an empty map rather than replacing.

Everything else stayed: the `SupplierFields` context and its tests, the managed
blueprint, the facade delegations, the boot-time guard registration, and the
gettext strings in all three locales. Flipping the flag to `true` restores the
feature and any data already stored. The modal and its edit mode are NOT behind
the flag — the owner asked for those and they stay.

`item_form_live_test.exs` pins the hidden behaviour (no manager, no columns, no
`custom_fields[` inputs, stored values survive); `supplier_fields_test.exs`
still covers the context in full, so the feature stays regression-tested while
invisible.

The rest of this document describes the design as built, for whoever turns it
back on.

---

## The split

**Entities owns the field DEFINITIONS. The catalogue owns the VALUES.**

This is the same split attribute sets use, one blueprint narrower — there,
entities holds the vocabulary (sets and their values) and a catalogue-owned
join table holds which item has which. Projects does the same thing with
workflow statuses: entities holds the vocabulary, `phoenix_kit_project_statuses`
holds the per-project rows.

| | |
|---|---|
| Blueprint | `catalogue_supplier_fields` — a singleton, `fields_definition` only, **no data records** |
| Owner | `catalogue_supplier` (see below) |
| Values | `phoenix_kit_cat_item_supplier_info.metadata["custom_fields"]` |
| Context | `PhoenixKitCatalogue.Catalogue.SupplierFields` |

Adding "Incoterm" or "Carton quantity" is now an admin action with no migration
and no deploy. The types offered are `text textarea number boolean date select` —
a curated entities subset. `image`/`video` are deliberately excluded: they are
picker + uuid references needing a page-level `MediaSelectorModal`, and an
unrenderable type would store a uuid nothing can choose.

## Why the commercial columns did NOT move

`unit_cost`, `currency`, `is_primary`, `valid_from`/`valid_to` and the
`{supplier_uuid, supplier_source}` reference stay as typed columns. Moving them
into entities would cost, concretely:

- **Money becomes a float.** Entities' `number` type casts with `Float.parse/1`
  (`form_builder.ex:1397`); the column is `NUMERIC(14,4)`.
- **"One primary supplier per item" stops being enforceable.** That is
  `phoenix_kit_cat_item_supplier_info_primary_uniq`, a partial unique index
  (V151). Entities has no DB-level constraint on `data` — it does not even
  enforce slug uniqueness.
- **Validity dates become strings.** `"YYYY-MM-DD"` in JSONB, so "which
  suppliers are current" stops being an indexed SQL predicate.
- **The supplier link has no home.** Entities' `relation` type renders
  "Entity relations coming soon"; the reference would be a bare uuid string
  with none of ADR-0001's source discriminator or resolution.

The attribute-sets design doc already ruled on this shape, writing about
variants: *"Do NOT model combos as entity records: they're per-item,
high-count, and relational."* Supplier rows are the same shape. That doc also
names this exact fallback: *"keep catalogue tables with a JSONB extras
column."*

## Two decisions worth not re-litigating

**The owner string is `catalogue_supplier`, not `catalogue`.**
`AttributeSets.list_sets/1` and `get_set/2` enumerate by
`Managed.owner(&1) == "catalogue"`. A shared owner would list this blueprint as
an attribute set and put it under the set deletion guard. A distinct owner keeps
both registries clean and gives this blueprint its own guard. Pinned by a test.

**Values live under `metadata["custom_fields"]`, not at the top of `metadata`.**
The column was unused, so an admin-invented key could have collided with a
future system key on the same JSONB. The namespace costs one level of nesting
and removes the whole class.

## Behaviour worth knowing

- **Validation runs before provisioning.** A rejected field must not leave a
  blueprint behind as a side effect, so shape checks precede
  `ensure_blueprint/1`; only the duplicate-key check needs the existing fields.
- **Removing a field keeps its stored values.** They stop being shown and come
  back if a field with the same key is re-added — same doctrine as entities' own
  field removal. The edit form seeds only currently-defined keys, or a removed
  field's orphaned value would fail the save with `:unknown_field` and lock the
  row out of editing entirely.
- **The blueprint cannot be deleted from the generic admin at all** (Managed
  refuses non-owner deletes). The registered guard additionally refuses an
  owner-side delete while any field is defined.
- **Entities off:** reads degrade quietly (`[]`, `%{}`, `nil`) so the supplier
  UI renders without extras; writes return `{:error, :entities_disabled}`. The
  Fields button hides.

## The modal

The add drawer became `<.modal>`, and the same modal gained an **edit** mode —
supplier rows previously had no edit path at all, which would have made a field
added later unfillable on existing rows.

- It renders **outside** the item `<.form>`. Nested `<form>` elements are
  invalid HTML and the browser drops the inner one, which would attach the
  supplier inputs to the item form.
- Errors render inside the modal. A page flash lands behind the backdrop.
- **Editing cannot re-point a row at a different supplier** — the supplier is
  the identity of the pair and price history keys on it. Remove and re-add.
- **Changing an existing cost is a revision, not an overwrite**:
  `revise_unit_cost/3` closes the current row and appends a successor, which is
  what feeds the History dialog. Setting a price for the first time, or clearing
  it, is an ordinary column write. Pinned by a test.
- Currency is upcased on save — the input is uppercase by CSS only, and the
  schema's `^[A-Z]{3}$` would have rejected what was actually submitted.

## Not done

- **No dedicated settings page.** The field manager opens from the Suppliers
  section of the item form, labelled as applying to every item. A catalogue-wide
  settings home would need a new route, a new tab, and an edit to the Catalogues
  subtab's exclusion regex; say the word if the boss wants it there.
- **Custom field values are not filterable or sortable.** They are JSONB with no
  GIN index, consistent with how entities stores everything.
- **No per-field required/validation rules.** Entities stores a `validation`
  sub-map but never reads it, so advertising it here would be a lie.
- **Manufacturers have no equivalent.** Suppliers only, per the current focus.
  A sibling blueprint under the same owner is the shape if it is ever wanted.
