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

## 4. Reference implementation

```elixir
defmodule MyApp.SmartRules do
  @moduledoc "Reference: applies CatalogueRule rows to a snapshot."

  alias PhoenixKitCatalogue.Schemas.{CatalogueRule, Item}

  @doc """
  `entries` is a list of `%{item: %Item{}, qty: integer}`. Items in a
  smart catalogue must have `:catalogue_rules` and the rules' nested
  `:referenced_catalogue` preloaded — see "Pitfalls" below.
  """
  def apply_rules(entries) do
    ref_sums = build_ref_sums(entries)
    Enum.map(entries, &compute_price(&1, ref_sums))
  end

  # Sum each standard catalogue's contribution to the order. Smart
  # items deliberately don't contribute — their prices are themselves
  # rule-computed and would yield 0 anyway.
  defp build_ref_sums(entries) do
    entries
    |> Enum.filter(&(&1.item.catalogue.kind == "standard"))
    |> Enum.group_by(& &1.item.catalogue_uuid)
    |> Map.new(fn {catalogue_uuid, group} ->
      {catalogue_uuid, Enum.reduce(group, Decimal.new(0), &Decimal.add(line_total(&1), &2))}
    end)
  end

  defp line_total(%{item: %Item{base_price: nil}}), do: Decimal.new(0)
  defp line_total(%{item: %Item{base_price: price}, qty: qty}),
    do: Decimal.mult(price, Decimal.new(qty))

  defp compute_price(%{item: %Item{catalogue: %{kind: "smart"}} = item} = entry, ref_sums) do
    price =
      Enum.reduce(item.catalogue_rules, Decimal.new(0), fn rule, acc ->
        Decimal.add(acc, rule_amount(rule, item, ref_sums))
      end)

    Map.put(entry, :computed_price, price)
  end

  defp compute_price(entry, _ref_sums), do: entry

  defp rule_amount(rule, item, ref_sums) do
    {value, unit} = CatalogueRule.effective(rule, item)
    ref_sum = Map.get(ref_sums, rule.referenced_catalogue_uuid, Decimal.new(0))

    case {value, unit} do
      {nil, _}        -> Decimal.new(0)
      {v, "percent"}  -> Decimal.div(Decimal.mult(v, ref_sum), Decimal.new(100))
      {v, "flat"}     -> v
      {_, _}          -> Decimal.new(0)
    end
  end
end
```

## 5. Pitfalls

### Smart items must be loaded with rules preloaded

Neither `Catalogue.list_items_for_category/1` nor
`Catalogue.search_items/2` preloads `:catalogue_rules`. Hosts that
render smart prices must do this themselves:

```elixir
items
|> MyApp.Repo.preload(catalogue_rules: :referenced_catalogue)
```

`Catalogue.list_catalogue_rules/1` and `Catalogue.catalogue_rule_map/1`
*do* preload the referenced catalogue, so if you fetch rules separately
you don't need to chain another preload.

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
