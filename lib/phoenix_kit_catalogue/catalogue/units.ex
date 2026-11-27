defmodule PhoenixKitCatalogue.Catalogue.Units do
  @moduledoc """
  Conversions between the units an item is counted, bought and priced in.

  Goods such as boards, panels, tiles or glass are counted in one unit
  (sheets) and traded in another (m³, m², packs). An item's `unit` is its
  **base unit**; from its dimensions and pack size this module converts a
  quantity — and a supplier's cost — between the base unit, `m2`, `m3` and
  `pack`.

  ## What converts to what

    * a **countable** base unit (`Item.countable_units/0`: `piece`, `set`,
      `pair`, `sheet`, `roll`) ↔ `m2` through `length_mm × width_mm`, and ↔
      `m3` through all three dimensions;
    * base unit `m2` ↔ `m3` through `thickness_mm` alone;
    * `pack` ↔ the base unit through the pack size — the supplier's
      (`supplier_info:`) when it has one, else the item's — and on through
      the base unit to `m2` / `m3`.

  Every other pair is `:not_convertible`.

  ## Exact arithmetic

  Everything is `Decimal`. Dimensions are the item's nominal ones and
  nothing is rounded: one conversion is a chain of multiplications and at
  most one division, made last, at `Decimal`'s context precision (28 significant
  digits by default). 2500 × 1250 × 18 mm is `0.05625` m³ and 1000 such
  sheets are `56.25` m³. **Rounding is the caller's** — to cents, to whole
  sheets, to whatever the document needs.

  Both functions are pure: they read the structs they are given and never
  the database.

  Public surface re-exported from `PhoenixKitCatalogue.Catalogue`.
  """

  alias PhoenixKitCatalogue.Schemas.Item
  alias PhoenixKitCatalogue.Schemas.ItemSupplierInfo

  @typedoc "Why a quantity could not be converted."
  @type convert_error ::
          :unknown_unit | :missing_dimensions | :missing_pack_size | :not_convertible

  @mm_to_m Decimal.new("0.001")
  @one Decimal.new(1)

  @doc """
  Converts `quantity` of `item` from one unit to another.

  `quantity` is a `Decimal`, an integer or a decimal string — never a
  float, which has already lost the digits this function keeps (an
  `ArgumentError`, like a string that is not a number).

  ## Options

    * `:supplier_info` — an `ItemSupplierInfo`; its `pack_size`, when set,
      is used for `pack` in place of the item's.

  ## Errors

    * `:unknown_unit` — a unit outside `Item.allowed_units/0`;
    * `:missing_dimensions` — the pair needs a dimension the item lacks;
    * `:missing_pack_size` — `pack` is involved and neither the supplier
      row nor the item has a pack size;
    * `:not_convertible` — no rule connects the two units for this item's
      base unit (`kg` to `m3`, `sheet` to `hour`, …).

  ## Examples

      # item: unit "sheet", 2500 × 1250 × 18 mm, pack_size 40
      Catalogue.convert(item, 1000, "sheet", "m3")
      #=> {:ok, Decimal.new("56.25000000000")}
      Catalogue.convert(item, "56.25", "m3", "sheet")
      #=> {:ok, Decimal.new("1000")}
      Catalogue.convert(item, 1, "pack", "m3", supplier_info: %ItemSupplierInfo{pack_size: Decimal.new(35)})
      #=> {:ok, Decimal.new("1.96875000000")}
  """
  @spec convert(Item.t(), Decimal.t() | integer() | String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Decimal.t()} | {:error, convert_error()}
  def convert(%Item{} = item, quantity, from_unit, to_unit, opts \\ []) do
    quantity = to_decimal!(quantity)

    with {:ok, {numerator, divisor}} <- ratio(item, from_unit, to_unit, opts) do
      {:ok, quantity |> Decimal.mult(numerator) |> divide(divisor)}
    end
  end

  @doc """
  A supplier's cost for one `unit` of the item.

  `supplier_info.unit_cost` is for one `cost_unit` (the item's base unit
  when that is `nil`); this expresses it per any unit `convert/5` can
  reach. The currency is not touched and nothing is rounded.

  Returns `{:error, :no_cost}` when the row has no `unit_cost`, otherwise
  `convert/5`'s errors. The row's own `pack_size` is used for `pack`.

  ## Examples

      # 830 per m³, the item a 2500 × 1250 × 18 mm sheet
      Catalogue.supplier_cost_per(item, info, "sheet")
      #=> {:ok, Decimal.new("46.68750000000")}
  """
  @spec supplier_cost_per(Item.t(), ItemSupplierInfo.t(), String.t()) ::
          {:ok, Decimal.t()} | {:error, :no_cost | convert_error()}
  def supplier_cost_per(%Item{}, %ItemSupplierInfo{unit_cost: nil}, _unit), do: {:error, :no_cost}

  def supplier_cost_per(%Item{} = item, %ItemSupplierInfo{unit_cost: cost} = info, unit) do
    cost_unit = info.cost_unit || base_unit(item)

    # One `unit` is numerator/divisor cost units. The cost is multiplied in
    # before the division, so 46.6875 per sheet is exactly 830 per m³ and
    # not 46.6875 × 17.777….
    with {:ok, {numerator, divisor}} <- ratio(item, unit, cost_unit, supplier_info: info) do
      {:ok, cost |> Decimal.mult(numerator) |> divide(divisor)}
    end
  end

  # How many `to_unit` one `from_unit` is, as {numerator, divisor}: every
  # multiplication is done before the single division the caller makes.
  defp ratio(item, from_unit, to_unit, opts) do
    units = Item.allowed_units()

    cond do
      from_unit not in units or to_unit not in units ->
        {:error, :unknown_unit}

      from_unit == to_unit ->
        {:ok, {@one, @one}}

      true ->
        pack_size = pack_size(item, Keyword.get(opts, :supplier_info))

        with {:ok, {from_num, from_den}} <- in_base(from_unit, item, pack_size),
             {:ok, {to_num, to_den}} <- in_base(to_unit, item, pack_size) do
          {:ok, {Decimal.mult(from_num, to_den), Decimal.mult(from_den, to_num)}}
        end
    end
  end

  # ── One unit, in base units, as a fraction {numerator, denominator} ──
  #
  # A fraction rather than a quotient, so "one m³ is 1 / 0.05625 sheets"
  # is never computed on its way to an answer that does not need it.

  defp in_base(unit, item, pack_size) do
    base = base_unit(item)

    cond do
      unit == base -> {:ok, {@one, @one}}
      unit == "pack" -> pack_in_base(pack_size)
      base in Item.countable_units() -> size_in_base(unit, item)
      base == "m2" and unit == "m3" -> thickness_in_base(item)
      true -> {:error, :not_convertible}
    end
  end

  defp pack_in_base(%Decimal{} = pack_size), do: {:ok, {pack_size, @one}}
  defp pack_in_base(nil), do: {:error, :missing_pack_size}

  # One countable thing is `area` m² and `volume` m³, so one m² is
  # 1/area of it.
  defp size_in_base("m2", item), do: per(Item.area_m2(item))
  defp size_in_base("m3", item), do: per(Item.volume_m3(item))
  defp size_in_base(_unit, _item), do: {:error, :not_convertible}

  # One m² of the item is `thickness` (in metres) m³.
  defp thickness_in_base(%Item{thickness_mm: %Decimal{} = thickness}),
    do: per(Decimal.mult(thickness, @mm_to_m))

  defp thickness_in_base(%Item{}), do: {:error, :missing_dimensions}

  defp per(%Decimal{} = size), do: {:ok, {@one, size}}
  defp per(nil), do: {:error, :missing_dimensions}

  defp base_unit(%Item{unit: unit}) when is_binary(unit), do: unit
  defp base_unit(%Item{}), do: "piece"

  defp pack_size(_item, %ItemSupplierInfo{pack_size: %Decimal{} = pack_size}), do: pack_size
  defp pack_size(%Item{pack_size: pack_size}, _supplier_info), do: pack_size

  defp divide(numerator, divisor) do
    if Decimal.equal?(divisor, @one), do: numerator, else: Decimal.div(numerator, divisor)
  end

  defp to_decimal!(%Decimal{} = quantity), do: quantity
  defp to_decimal!(quantity) when is_integer(quantity), do: Decimal.new(quantity)

  defp to_decimal!(quantity) when is_binary(quantity) do
    case Decimal.parse(String.trim(quantity)) do
      {decimal, ""} -> decimal
      _other -> raise ArgumentError, "not a decimal quantity: #{inspect(quantity)}"
    end
  end

  defp to_decimal!(quantity) do
    raise ArgumentError,
          "quantity must be a Decimal, an integer or a decimal string, got: #{inspect(quantity)}"
  end
end
