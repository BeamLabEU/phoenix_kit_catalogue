# Smart Catalogues — End-to-End Integration Guide

This guide walks a host application through working with **smart
catalogues**: catalogues whose items price themselves as a function of
*other* catalogues. The schema and CRUD APIs are documented per-module;
this guide covers the **consumer side** — how a host turns rule rows
plus a live order into computed prices.

> Looking for the data model? See `PhoenixKitCatalogue.Catalogue` and
> `PhoenixKitCatalogue.Schemas.CatalogueRule`. The repo's `AGENTS.md`
> "Smart catalogues" section is the schema-level reference; this guide
> is the integration-side companion.

## 1. Concepts

### Catalogue `kind`

Every catalogue has a `kind` field — `"standard"` (the default) or
`"smart"`. A standard catalogue holds items with intrinsic prices.
A smart catalogue holds items whose price is computed from rules that
reference other (standard) catalogues.

Concrete example: a "Services" smart catalogue holds a "Delivery" item
with a rule "5% of Kitchen + 3% of Plumbing + $20 flat of Hardware".
Each leg references a standard catalogue. The math happens host-side at
order time — this module only stores the user's intent.

### `default_value` / `default_unit` on items

Smart items have two extra columns that ride on the existing `Item`
schema: `default_value` (`Decimal`, nullable) and `default_unit`
(`String`, nullable, vocabulary `"percent"` / `"flat"` in V1).
Standard items leave both `nil`.

These serve two roles:

1. **Standalone fee** — for a smart item with no rules, `default_value`
   + `default_unit` *is* the price (e.g. `default_value: 50`,
   `default_unit: "flat"` means "this item costs $50 flat").
2. **Fallback for rule rows** — a `CatalogueRule` row's `value` is
   nullable; when `nil`, it inherits from the item's `default_value`.
   The same is true at the data layer for `unit`, but **the UI does
   not surface unit inheritance** — see the duality note below.

### `CatalogueRule` rows

Each row is one `(item, referenced_catalogue, value, unit, position)`
tuple. The item lives in a smart catalogue; the referenced catalogue
**must be `kind: "standard"`** (the changeset rejects smart→smart
references — see issue #16). Self-references are rejected by the same
guard, since the only way an item could self-reference is if its own
catalogue were the referenced one, which is smart by definition.

`UNIQUE(item_uuid, referenced_catalogue_uuid)` prevents duplicates;
deleting a referenced catalogue cascades the rule rows away (FK has
`ON DELETE CASCADE`).

## 2. Schema overview

```
Catalogue (kind: "standard" | "smart")
  │
  ├─ Category (mostly used on standard catalogues)
  │   └─ Item
  │       ├─ default_value, default_unit      (smart-only, nullable)
  │       └─ has_many :catalogue_rules
  │
  └─ CatalogueRule
        ├─ item_uuid                           (the smart-catalogue item)
        ├─ referenced_catalogue_uuid           (must be kind: "standard")
        ├─ value, unit                         (nullable; inherits from item.default_value)
        └─ position                            (UI ordering)
```

## 3. Worked example

```elixir
alias PhoenixKitCatalogue.Catalogue

# A standard catalogue with priced items
{:ok, kitchen}    = Catalogue.create_catalogue(%{name: "Kitchen"})
{:ok, panel}      = Catalogue.create_item(%{
  name: "Oak Panel",
  catalogue_uuid: kitchen.uuid,
  base_price: Decimal.new("100")
})
{:ok, hinge}      = Catalogue.create_item(%{
  name: "Brass Hinge",
  catalogue_uuid: kitchen.uuid,
  base_price: Decimal.new("8")
})

# A smart catalogue with a service item
{:ok, services}   = Catalogue.create_catalogue(%{name: "Services", kind: "smart"})
{:ok, delivery}   = Catalogue.create_item(%{
  name: "Delivery",
  catalogue_uuid: services.uuid,
  default_value: Decimal.new("5"),
  default_unit: "percent"
})

# Replace-all the delivery item's rules in one transaction
{:ok, _rules} = Catalogue.put_catalogue_rules(delivery, [
  %{referenced_catalogue_uuid: kitchen.uuid, value: Decimal.new("15"), unit: "percent"}
])
```

A consumer building a price for an order with one panel and one
delivery would:

1. Compute the standard line totals: `panel.base_price * 1 = 100`.
2. Build a per-catalogue ref-sum: `%{kitchen.uuid => 100}`.
3. For the delivery item, sum each rule: `15% × 100 = 15`.
4. Set the delivery line's price to `15`.

## 4. Computing prices

Use `Catalogue.evaluate_smart_rules/2` — the canonical implementation
of the algorithm. It pairs with `Catalogue.item_pricing/1` for the
smart-catalogue case: standard entries pass through unchanged, smart
items get a computed price written to a configurable key.

```elixir
alias PhoenixKitCatalogue.Catalogue

# Items must have :catalogue (and, for smart items, :catalogue_rules
# with :referenced_catalogue) preloaded. The bulk fetchers accept a
# :preload opt for exactly this:
items =
  Catalogue.list_items_for_catalogue(catalogue_uuid,
    preload: [catalogue_rules: :referenced_catalogue]
  )

entries = Enum.map(items, &%{item: &1, qty: qty_for(&1)})

priced = Catalogue.evaluate_smart_rules(entries)
# => standard entries unchanged; smart entries get :smart_price
```

Default behaviour:

  * `:line_total` — `entry.item.base_price * entry.qty` (returns 0
    when `base_price` is `nil`).
  * `:write_to` — `:smart_price`.
  * Smart items with no rules get `Decimal.new("0.00")`.
  * A rule referencing a catalogue not present in `entries` contributes 0.

### Customizing line_total

The one piece of consumer policy is what an entry contributes to its
catalogue's ref-sum. Override `:line_total` to apply discounts before
smart-pricing, exclude tax, or compose your own snapshot rules:

```elixir
discounted_line_total = fn %{item: i, qty: q} ->
  base = i.base_price |> Decimal.mult(Decimal.new(q))
  markup = Decimal.add(Decimal.new(1), Decimal.div(i.markup_percentage || 0, 100))
  discount = Decimal.sub(Decimal.new(1), Decimal.div(i.discount_percentage || 0, 100))
  base |> Decimal.mult(markup) |> Decimal.mult(discount)
end

Catalogue.evaluate_smart_rules(entries, line_total: discounted_line_total)
```

### Customizing the output key

For consumers that want a different field on each entry (e.g. to align
with their snapshot's column naming):

```elixir
Catalogue.evaluate_smart_rules(entries, write_to: :computed_price)
```

## 5. Pitfalls

### Smart items must be loaded with rules preloaded

`Catalogue.list_items_for_category/2`, `list_items_for_catalogue/2`,
`list_uncategorized_items/2`, `search_items/2`, `get_item/2`,
`get_item!/2`, and `list_items_by_uuids/2` all accept a `:preload` opt
that merges into their default preloads. For smart-pricing, pass:

```elixir
Catalogue.list_items_for_catalogue(uuid,
  preload: [catalogue_rules: :referenced_catalogue]
)
```

`evaluate_smart_rules/2` raises `ArgumentError` if `:catalogue` or
`:catalogue_rules` is `%Ecto.Association.NotLoaded{}` on any entry —
no silent zero-pricing. `Catalogue.list_catalogue_rules/1` and
`Catalogue.catalogue_rule_map/1` *do* preload the referenced catalogue
already, so if you fetch rules separately you don't need to chain
another preload.

### `unit` does not inherit at the UI layer (only `value` does)

`CatalogueRule.effective/2` falls back to `item.default_unit` for
backward compat with rows persisted before the picker pinned `unit`
explicitly. New writes from the form always seed `unit: "percent"` (or
the dropdown's selected value). When you build a host UI for editing
rules, do **not** rely on the user changing `default_unit` to retroact
into rule rows — each row carries its own.

`value` is the opposite: a NULL `value` on a rule row inherits
`item.default_value` at math time, and the picker surfaces this with
an `Inherit: N` placeholder. Treat `default_value` as a "set 5% across
all my legs" shortcut.

### Smart→smart references are rejected at the changeset layer

Trying to point a rule at a smart catalogue returns
`{:error, %Ecto.Changeset{}}` with the error
`"must reference a standard catalogue, not a smart catalogue"` on
`:referenced_catalogue_uuid`. The picker in `ItemFormLive` already
filters candidates to `Catalogue.list_catalogues(kind: :standard)`, so
the UI never offers a smart catalogue as a candidate. Programmatic
callers (CLI, IEx, scripts) hit the changeset guard.

### Referencing a deleted catalogue

Soft-delete sets `status: "deleted"` but leaves the FK valid, so
existing rule rows survive the catalogue's deletion. The
`Catalogue.list_catalogue_rules/1` preload carries the
`referenced_catalogue.status` so the UI can dim or warn on dead refs.
Hard delete cascades the rule rows via `ON DELETE CASCADE`.

### Decimal precision

`Decimal.div` keeps full precision (28 digits by default). Hosts that
serialize prices as strings should `Decimal.round(2)` (or whatever
your store conventions require) before write — otherwise you'll ship
`14.99999999999999999999999999` to the client.

### Live UI re-computation

If your host computes smart prices only at order-save time, users
won't see the smart row update during editing. The reference
implementation above is a pure function — call it from your LV's
render path so prices stay live as quantities change.
