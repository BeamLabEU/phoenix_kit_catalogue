defmodule PhoenixKitCatalogue.Import.Mapper do
  @moduledoc """
  Maps file columns to catalogue fields and transforms row data into
  validated item attribute maps ready for insertion.
  """

  alias PhoenixKit.Utils.Multilang

  @type target ::
          :name
          | :description
          | :sku
          | :base_price
          | :unit
          | :category
          | :skip
          | {:data, String.t()}

  @type column_mapping :: %{
          column_index: non_neg_integer(),
          header: String.t(),
          target: target()
        }

  @type import_plan :: %{
          items: [map()],
          categories_to_create: [String.t()],
          custom_fields: [String.t()],
          errors: [{non_neg_integer(), String.t()}],
          stats: %{total: non_neg_integer(), valid: non_neg_integer(), invalid: non_neg_integer()}
        }

  @unit_aliases %{
    "tk" => "piece",
    "piece" => "piece",
    "pcs" => "piece",
    "pc" => "piece",
    "stk" => "piece",
    "kmpl" => "set",
    "kpl" => "set",
    "set" => "set",
    "kit" => "set",
    "paar" => "pair",
    "pair" => "pair",
    "leht" => "sheet",
    "sheet" => "sheet",
    "m2" => "m2",
    "m²" => "m2",
    "sqm" => "m2",
    "jm" => "running_meter",
    "rm" => "running_meter",
    "lm" => "running_meter",
    "running_meter" => "running_meter"
  }

  @header_patterns %{
    sku: ~w(sku artikkel article code kood nr number art artikelnr item_code product_code),
    name: ~w(name nimi nimetus kirjeldus description bezeichnung toode product),
    base_price: ~w(price hind preis cost maksumus kulu base_price baseprice),
    unit: ~w(unit uhik einheit masseinheit measure uom)
  }

  # ── Public API ────────────────────────────────────────────────

  @doc """
  Returns available mapping targets with display labels.
  """
  @spec available_targets() :: [{target(), String.t()}]
  def available_targets do
    [
      {:skip, "— Skip —"},
      {:name, "Item Name"},
      {:description, "Description"},
      {:sku, "Article Code"},
      {:base_price, "Base Price"},
      {:unit, "Unit of Measure"},
      {:category, "Create Categories"}
    ]
  end

  @doc """
  Auto-detects column mappings by matching headers against known patterns.
  Uses score-based matching — normalizes headers (lowercase, strip diacritics/whitespace).
  """
  @spec auto_detect_mappings([String.t()]) :: [column_mapping()]
  def auto_detect_mappings(headers) do
    used_targets = MapSet.new()

    {mappings, _used} =
      headers
      |> Enum.with_index()
      |> Enum.map_reduce(used_targets, fn {header, idx}, used ->
        target = detect_target(header, used)
        mapping = %{column_index: idx, header: header, target: target}
        new_used = if target != :skip, do: MapSet.put(used, target), else: used
        {mapping, new_used}
      end)

    mappings
  end

  @doc """
  Builds an import plan from column mappings and parsed rows.

  Validates all rows, normalizes units and prices, collects errors.
  The `unit_map` option allows custom unit value mappings from the UI.
  """
  @spec build_import_plan([column_mapping()], [[String.t()]], keyword()) :: import_plan()
  def build_import_plan(mappings, rows, opts \\ []) do
    unit_map = Keyword.get(opts, :unit_map, %{})
    custom_fields = extract_custom_fields(mappings)

    {items, errors} =
      rows
      |> Enum.with_index(1)
      |> Enum.reduce({[], []}, fn {row, row_idx}, {items_acc, errors_acc} ->
        case build_item_attrs(mappings, row, unit_map) do
          {:ok, attrs} ->
            {[attrs | items_acc], errors_acc}

          {:error, reason} ->
            {items_acc, [{row_idx, reason} | errors_acc]}
        end
      end)

    items = Enum.reverse(items)
    errors = Enum.reverse(errors)

    categories_to_create =
      mappings
      |> Enum.find(fn m -> m.target == :category end)
      |> case do
        nil ->
          []

        %{column_index: idx} ->
          rows
          |> Enum.map(fn row -> Enum.at(row, idx, "") end)
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq()
          |> Enum.sort()
      end

    %{
      items: items,
      categories_to_create: categories_to_create,
      custom_fields: custom_fields,
      errors: errors,
      stats: %{
        total: length(rows),
        valid: length(items),
        invalid: length(errors)
      }
    }
  end

  @doc """
  Extracts unique values from a specific column across all rows.
  Useful for showing unit mapping UI or category preview.
  """
  @spec unique_column_values([[String.t()]], non_neg_integer()) :: [String.t()]
  def unique_column_values(rows, column_index) do
    rows
    |> Enum.map(fn row -> Enum.at(row, column_index, "") end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Checks for duplicate rows within the import file.
  Returns the count of rows that are exact duplicates of another row.
  """
  @spec detect_file_duplicates([[String.t()]]) :: non_neg_integer()
  def detect_file_duplicates(rows) do
    total = length(rows)
    unique = rows |> Enum.uniq() |> length()
    total - unique
  end

  @doc """
  Checks how many items from the import plan already exist in the catalogue
  with identical field values, category, and language.

  ## Options

    * `:category_uuid` — the target category UUID (nil = uncategorized)
    * `:language` — the import language code (nil = no multilang)
  """
  @spec detect_existing_duplicates(import_plan(), String.t(), keyword()) :: non_neg_integer()
  def detect_existing_duplicates(plan, catalogue_uuid, opts \\ []) do
    category_uuid = Keyword.get(opts, :category_uuid)
    language = Keyword.get(opts, :language)

    import Ecto.Query

    categorized =
      PhoenixKitCatalogue.Schemas.Item
      |> join(:inner, [i], c in PhoenixKitCatalogue.Schemas.Category,
        on: i.category_uuid == c.uuid
      )
      |> where([i, c], c.catalogue_uuid == ^catalogue_uuid and i.status != "deleted")
      |> PhoenixKit.RepoHelper.repo().all()

    uncategorized =
      PhoenixKitCatalogue.Schemas.Item
      |> where([i], is_nil(i.category_uuid) and i.status != "deleted")
      |> PhoenixKit.RepoHelper.repo().all()

    existing_items = categorized ++ uncategorized

    Enum.count(plan.items, fn import_item ->
      Enum.any?(existing_items, fn existing ->
        fields_match?(import_item, existing, category_uuid, language)
      end)
    end)
  end

  @doc """
  Checks if an import item matches an existing item on all mapped fields,
  including category and language.

  ## Options

    * `:category_uuid` — the target category UUID (nil = uncategorized)
    * `:language` — the import language code (nil = no multilang)
  """
  @spec item_matches_existing?(map(), map(), keyword()) :: boolean()
  def item_matches_existing?(import_item, existing, opts \\ []) do
    category_uuid = Keyword.get(opts, :category_uuid)
    language = Keyword.get(opts, :language)
    fields_match?(import_item, existing, category_uuid, language)
  end

  defp fields_match?(import_item, existing, category_uuid, language) do
    name_matches?(import_item, existing) and
      sku_matches?(import_item, existing) and
      price_matches?(import_item, existing) and
      unit_matches?(import_item, existing) and
      category_matches?(existing, category_uuid) and
      language_matches?(import_item, existing, language)
  end

  defp name_matches?(import_item, existing), do: import_item[:name] == existing.name

  defp sku_matches?(import_item, existing),
    do: normalize_blank(import_item[:sku]) == normalize_blank(existing.sku)

  defp unit_matches?(import_item, existing),
    do: (import_item[:unit] || "piece") == (existing.unit || "piece")

  defp price_matches?(import_item, existing) do
    case {import_item[:base_price], existing.base_price} do
      {nil, nil} -> true
      {nil, _} -> false
      {_, nil} -> false
      {a, b} -> Decimal.equal?(a, b)
    end
  end

  defp category_matches?(existing, nil), do: is_nil(existing.category_uuid)
  defp category_matches?(existing, uuid), do: existing.category_uuid == uuid

  defp language_matches?(_import_item, _existing, nil), do: true

  defp language_matches?(import_item, existing, lang) do
    existing_data = existing.data || %{}
    lang_data = Multilang.get_language_data(existing_data, lang)
    import_item[:name] == lang_data["_name"]
  end

  defp normalize_blank(nil), do: nil
  defp normalize_blank(""), do: nil
  defp normalize_blank(v), do: v

  @doc """
  Normalizes a unit value using the user-provided unit map and built-in aliases.
  """
  @spec normalize_unit(String.t(), map()) :: String.t()
  def normalize_unit(value, unit_map \\ %{}) do
    normalized = String.downcase(String.trim(value))

    cond do
      Map.has_key?(unit_map, value) -> unit_map[value]
      Map.has_key?(unit_map, normalized) -> unit_map[normalized]
      Map.has_key?(@unit_aliases, normalized) -> @unit_aliases[normalized]
      true -> "piece"
    end
  end

  @doc """
  Normalizes a price string to a Decimal.
  Handles comma-as-decimal ("4,88"), currency symbols, whitespace.
  """
  @spec normalize_price(String.t()) :: {:ok, Decimal.t()} | :error
  def normalize_price(value) do
    cleaned =
      value
      |> String.trim()
      |> String.replace(~r/[€$£\s]/, "")

    # Handle comma as decimal separator: "4,88" -> "4.88"
    # But not thousands separator: "1,234.56" stays as-is
    cleaned =
      cond do
        String.contains?(cleaned, ".") and String.contains?(cleaned, ",") ->
          # Has both: comma is thousands separator, dot is decimal
          String.replace(cleaned, ",", "")

        String.contains?(cleaned, ",") ->
          # Only comma: it's the decimal separator
          String.replace(cleaned, ",", ".")

        true ->
          cleaned
      end

    case Decimal.parse(cleaned) do
      {decimal, ""} ->
        if Decimal.compare(decimal, Decimal.new(0)) in [:gt, :eq] do
          {:ok, decimal}
        else
          :error
        end

      _ ->
        :error
    end
  end

  # ── Private ───────────────────────────────────────────────────

  defp detect_target(header, used_targets) do
    normalized = normalize_header(header)

    match =
      Enum.find(@header_patterns, fn {target, patterns} ->
        target not in MapSet.to_list(used_targets) and
          Enum.any?(patterns, fn pattern ->
            String.contains?(normalized, pattern)
          end)
      end)

    case match do
      {target, _patterns} -> target
      nil -> :skip
    end
  end

  defp normalize_header(header) do
    header
    |> String.downcase()
    |> strip_diacritics()
    |> String.replace(~r/[^a-z0-9\s_]/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  @diacritics_regex ~r/\p{Mn}/u

  defp strip_diacritics(string) do
    string
    |> String.normalize(:nfd)
    |> String.replace(@diacritics_regex, "")
    # Handle specific characters not decomposed by NFD
    |> String.replace("ö", "o")
    |> String.replace("ü", "u")
    |> String.replace("ä", "a")
    |> String.replace("õ", "o")
    |> String.replace("ø", "o")
    |> String.replace("ß", "ss")
  end

  defp build_item_attrs(mappings, row, unit_map) do
    attrs =
      Enum.reduce(mappings, %{}, fn mapping, acc ->
        value = Enum.at(row, mapping.column_index, "")
        apply_mapping(acc, mapping.target, value, unit_map)
      end)

    validate_item_attrs(attrs)
  end

  defp apply_mapping(acc, :skip, _value, _unit_map), do: acc
  defp apply_mapping(acc, :name, value, _unit_map), do: Map.put(acc, :name, String.trim(value))

  defp apply_mapping(acc, :description, value, _unit_map),
    do: Map.put(acc, :description, String.trim(value))

  defp apply_mapping(acc, :sku, value, _unit_map), do: Map.put(acc, :sku, String.trim(value))

  defp apply_mapping(acc, :base_price, value, _unit_map) do
    case normalize_price(value) do
      {:ok, decimal} -> Map.put(acc, :base_price, decimal)
      :error -> Map.put(acc, :_price_error, value)
    end
  end

  defp apply_mapping(acc, :unit, value, unit_map) do
    normalized = normalize_unit(value, unit_map)
    data = Map.get(acc, :data, %{})

    acc
    |> Map.put(:unit, normalized)
    |> Map.put(:data, Map.put(data, "original_unit", String.trim(value)))
  end

  defp apply_mapping(acc, :category, value, _unit_map),
    do: Map.put(acc, :_category_name, String.trim(value))

  defp apply_mapping(acc, {:data, field_name}, value, _unit_map) do
    data = Map.get(acc, :data, %{})
    Map.put(acc, :data, Map.put(data, field_name, String.trim(value)))
  end

  defp validate_item_attrs(attrs) do
    cond do
      not Map.has_key?(attrs, :name) or attrs[:name] == "" ->
        {:error, "Missing item name"}

      Map.has_key?(attrs, :_price_error) ->
        {:error, "Invalid price: #{attrs[:_price_error]}"}

      true ->
        {:ok, Map.drop(attrs, [:_price_error])}
    end
  end

  defp extract_custom_fields(mappings) do
    mappings
    |> Enum.filter(fn m -> match?({:data, _}, m.target) end)
    |> Enum.map(fn %{target: {:data, name}} -> name end)
  end
end
