defmodule PhoenixKitCatalogue.Catalogue.SmartPricing do
  @moduledoc """
  Public smart-pricing evaluator — the canonical implementation of the
  algorithm previously documented as a copy-paste reference in
  `guides/smart_catalogues.md`.

  Mirrors `PhoenixKitCatalogue.Catalogue.item_pricing/1` for the smart
  case: standard items pass through unchanged; smart items get a
  computed price written to a configurable key on the entry map.

  The unit semantics (`"percent"`, `"flat"`, `nil` value) and the
  `CatalogueRule.effective/2` inheritance live here. The one piece of
  consumer policy — what counts as an entry's contribution to its
  catalogue's ref-sum — is injected via the `:line_total` option.

  Public surface is re-exported from `PhoenixKitCatalogue.Catalogue` as
  `evaluate_smart_rules/2`.

  ## Required preloads

  Every entry's `item` must have `:catalogue` preloaded (used for the
  `kind` check). Smart items must additionally have `:catalogue_rules`
  preloaded with `:referenced_catalogue` nested inside it. The bulk
  fetchers in `Catalogue` accept a `:preload` option for exactly this:

      Catalogue.list_items_for_catalogue(uuid,
        preload: [catalogue_rules: :referenced_catalogue]
      )

  Missing preloads raise `ArgumentError` with a hint — better than a
  silent `%Ecto.Association.NotLoaded{}` propagating into `Decimal`
  math and crashing further downstream.

  ## No rules → 0

  A smart item with no rule rows is written `Decimal.new("0.00")`,
  matching the reference implementation in the guide. The
  `default_value` + `default_unit` "ruleless intrinsic fee" pattern is
  not auto-applied — consumers wanting that behavior should post-process
  the returned entries (the data is right there on `item.default_*`).
  """

  alias PhoenixKitCatalogue.Schemas.{CatalogueRule, Item}

  @type entry :: %{
          required(:item) => Item.t(),
          required(:qty) => number() | Decimal.t(),
          optional(any) => any
        }

  @doc """
  Computes a price for every smart item in `entries`. Standard entries
  pass through unchanged.

  ## Options

    * `:line_total` — `(entry -> Decimal.t())`. Computes the
      contribution of one entry to its catalogue's ref-sum. Defaults to
      `entry.item.base_price * entry.qty` (returns `Decimal.new(0)`
      when `base_price` is `nil`). Override to apply discounts before
      smart-pricing, exclude tax, or anything else your line-total
      means in your domain.

    * `:write_to` — atom key on each smart-item entry to receive the
      computed price. Default `:smart_price`. The value is a
      `Decimal.t()` rounded to 2 decimal places. Standard entries are
      not modified.

  ## Examples

      # Default behavior — line_total = base_price × qty
      Catalogue.evaluate_smart_rules([
        %{item: panel, qty: 1},
        %{item: hinge, qty: 4},
        %{item: delivery, qty: 1}
      ])
      #=> [
      #   %{item: panel, qty: 1},
      #   %{item: hinge, qty: 4},
      #   %{item: delivery, qty: 1, smart_price: Decimal.new("19.80")}
      # ]

      # Custom line_total: pre-discount the standard side
      Catalogue.evaluate_smart_rules(entries,
        line_total: fn %{item: i, qty: q} ->
          base = i.base_price |> Decimal.mult(q)
          markup = Decimal.add(Decimal.new(1), Decimal.div(i.markup_percentage || 0, 100))
          discount = Decimal.sub(Decimal.new(1), Decimal.div(i.discount_percentage || 0, 100))
          base |> Decimal.mult(markup) |> Decimal.mult(discount)
        end,
        write_to: :computed_price
      )
  """
  @spec evaluate_smart_rules([entry()], keyword()) :: [entry()]
  def evaluate_smart_rules(entries, opts \\ []) when is_list(entries) do
    line_total_fn = Keyword.get(opts, :line_total, &default_line_total/1)
    write_to = Keyword.get(opts, :write_to, :smart_price)

    ref_sums = build_ref_sums(entries, line_total_fn)

    Enum.map(entries, &compute_price(&1, ref_sums, write_to))
  end

  # Sum each standard catalogue's contribution to the order. Smart items
  # deliberately don't contribute — their prices are themselves
  # rule-computed and would yield the wrong answer (or 0) if mixed in.
  defp build_ref_sums(entries, line_total_fn) do
    entries
    |> Enum.filter(&standard?/1)
    |> Enum.group_by(& &1.item.catalogue_uuid)
    |> Map.new(fn {uuid, group} ->
      total =
        Enum.reduce(group, Decimal.new(0), fn entry, acc ->
          Decimal.add(acc, line_total_fn.(entry))
        end)

      {uuid, total}
    end)
  end

  # Pattern-match on the preloaded `kind`. NotLoaded is a programmer
  # error — raise loudly with a hint rather than silently returning 0
  # everywhere or crashing inside Decimal math.
  defp standard?(%{item: %Item{catalogue: %{kind: "standard"}}}), do: true
  defp standard?(%{item: %Item{catalogue: %{kind: "smart"}}}), do: false

  defp standard?(%{item: %Item{catalogue: %Ecto.Association.NotLoaded{}}}) do
    raise ArgumentError,
          "evaluate_smart_rules/2 requires :catalogue to be preloaded on every entry's item. " <>
            "Use Catalogue.list_items_*(... preload: [catalogue_rules: :referenced_catalogue]) " <>
            "or chain Repo.preload before calling."
  end

  defp compute_price(
         %{item: %Item{catalogue: %{kind: "smart"}} = item} = entry,
         ref_sums,
         write_to
       ) do
    case item.catalogue_rules do
      %Ecto.Association.NotLoaded{} ->
        raise ArgumentError,
              "evaluate_smart_rules/2 requires :catalogue_rules to be preloaded on smart items. " <>
                "Pass `preload: [catalogue_rules: :referenced_catalogue]` to Catalogue.list_items_*."

      rules when is_list(rules) ->
        price =
          rules
          |> Enum.reduce(Decimal.new(0), fn rule, acc ->
            Decimal.add(acc, rule_amount(rule, item, ref_sums))
          end)
          |> Decimal.round(2)

        Map.put(entry, write_to, price)
    end
  end

  # Standard entries pass through untouched. Same shape coming in and out.
  defp compute_price(entry, _ref_sums, _write_to), do: entry

  defp rule_amount(rule, item, ref_sums) do
    {value, unit} = CatalogueRule.effective(rule, item)
    ref_sum = Map.get(ref_sums, rule.referenced_catalogue_uuid, Decimal.new(0))

    case {value, unit} do
      {nil, _} -> Decimal.new(0)
      {v, "percent"} -> Decimal.div(Decimal.mult(v, ref_sum), Decimal.new(100))
      {v, "flat"} -> v
      {_, _} -> Decimal.new(0)
    end
  end

  defp default_line_total(%{item: %Item{base_price: nil}}), do: Decimal.new(0)

  defp default_line_total(%{item: %Item{base_price: price}, qty: qty}) do
    Decimal.mult(price, to_decimal(qty))
  end

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)
end
