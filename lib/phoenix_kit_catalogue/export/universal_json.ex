defmodule PhoenixKitCatalogue.Export.UniversalJson do
  @moduledoc """
  Universal JSON export encoder.

  Produces a generic, destination-agnostic JSON dump of catalogue items
  across one or more catalogues.

  ## Output shape

      {
        "catalogues": [{"uuid": "...", "name": "...", "ai_notes": ""}, ...],
        "exported_at": "2026-06-26T16:00:00Z",
        "index": 1111111111,
        "items": [
          {"name": "...", "sku": "...", "base_price": "2222.00", "unit": "piece",
           "length_mm": "2500", "width_mm": "1250", "thickness_mm": "18",
           "pack_size": "40",
           "item_type": "", "ai_notes": "", "catalogue": "...",
           "suppliers": [
             {"name": "...", "sku": "...", "cost": "830", "currency": "EUR",
              "cost_unit": "m3", "pack_size": "35", "primary": true}
           ],
           "dependencies": [
             {"type": "item", "uuid": "...", "name": "...", "sku": "...",
              "catalogue": "...", "quantity": "8", "note": "pick by wood type"}
           ]}
        ]
      }

  The three dimensions and the pack size are exact decimal strings, `""`
  when the item has none; the area and volume are not exported — they
  follow from the dimensions. `suppliers` lists the item's current
  supplier rows, the primary first: `cost` is for one `cost_unit` (`""` =
  the item's `unit`) and `pack_size` is that supplier's own (`""` = the
  item's). An import reads the first one back.

  A dependency names its target three ways — the uuid (exact in the same
  database), the SKU for an item and the names (catalogue, category) — so
  an import into another database can still find it; see
  `Import.Executor`.

  Filename includes the export date and local time (`YYYY-MM-DD HH-MM`): a
  single catalogue is named after the catalogue (e.g.
  `"My Catalogue 2026-06-26 19-19.json"`); multiple catalogues produce
  `"Catalogues 2026-06-26 19-19.json"`.
  """

  alias PhoenixKitCatalogue.Export.Pro100

  @doc """
  Renders the universal JSON export.

  `ctx` must have keys:
  - `:items` — list of items (with `:catalogue` association preloaded)
  - `:index` — unix timestamp integer
  - `:catalogues` — list of catalogue structs

  Returns `{filename, iodata, mime_type}`.
  """
  def render(ctx) do
    %{items: items, index: index, catalogues: catalogues} = ctx
    dependencies = Map.get(ctx, :dependencies, %{})
    suppliers = Map.get(ctx, :suppliers, %{})

    payload = %{
      "catalogues" => Enum.map(catalogues, &encode_catalogue/1),
      "exported_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "index" => index,
      "items" =>
        Enum.map(items, fn item ->
          uuid = Map.get(item, :uuid)
          encode_item(item, Map.get(dependencies, uuid, []), Map.get(suppliers, uuid, []))
        end)
    }

    filename = build_filename(catalogues, Pro100.datetime_str(index))
    json = Jason.encode!(payload, pretty: true)
    {filename, json, "application/json"}
  end

  defp encode_catalogue(catalogue) do
    %{
      "uuid" => catalogue.uuid,
      "name" => catalogue.name,
      "ai_notes" => Map.get(catalogue, :ai_notes) || ""
    }
  end

  defp encode_item(item, dependencies, suppliers) do
    catalogue_name =
      case item.catalogue do
        %{name: name} -> name
        _ -> nil
      end

    %{
      "name" => item.name,
      "sku" => item.sku,
      "base_price" => Pro100.format_price(item.base_price),
      "unit" => item.unit,
      "length_mm" => decimal_text(Map.get(item, :length_mm)),
      "width_mm" => decimal_text(Map.get(item, :width_mm)),
      "thickness_mm" => decimal_text(Map.get(item, :thickness_mm)),
      "pack_size" => decimal_text(Map.get(item, :pack_size)),
      # The item's OWN type: "" means "as in the catalogue", so an import
      # back leaves it inheriting rather than freezing today's default.
      "item_type" => Map.get(item, :item_type) || "",
      "ai_notes" => Map.get(item, :ai_notes) || "",
      "catalogue" => catalogue_name,
      "suppliers" => Enum.map(suppliers, &encode_supplier/1),
      "dependencies" => Enum.flat_map(dependencies, &encode_dependency/1)
    }
  end

  # The name is the row's snapshot — what the supplier was called when the
  # row was written — so the export asks no other module for it.
  defp encode_supplier(info) do
    %{
      "name" => info.supplier_name_snapshot || "",
      "sku" => info.supplier_sku || "",
      "cost" => decimal_text(info.unit_cost),
      "currency" => info.currency || "",
      "cost_unit" => info.cost_unit || "",
      "pack_size" => decimal_text(info.pack_size),
      "primary" => info.is_primary == true
    }
  end

  # Every digit, no trailing zeros, never an exponent; "" for none.
  defp decimal_text(%Decimal{} = value),
    do: value |> Decimal.normalize() |> Decimal.to_string(:normal)

  defp decimal_text(_none), do: ""

  defp encode_dependency(dependency) do
    case target(dependency) do
      nil ->
        []

      {type, record, catalogue} ->
        [
          %{
            "type" => type,
            "uuid" => record.uuid,
            "name" => record.name,
            "sku" => if(type == "item", do: record.sku),
            "catalogue" => catalogue && catalogue.name,
            "quantity" =>
              dependency.quantity |> Decimal.normalize() |> Decimal.to_string(:normal),
            "note" => dependency.note || ""
          }
        ]
    end
  end

  defp target(%{target_catalogue: %{uuid: _} = catalogue}), do: {"catalogue", catalogue, nil}

  defp target(%{target_category: %{uuid: _} = category}),
    do: {"category", category, loaded(category.catalogue)}

  defp target(%{target_item: %{uuid: _} = item}), do: {"item", item, loaded(item.catalogue)}
  defp target(_dependency), do: nil

  defp loaded(%{uuid: _} = record), do: record
  defp loaded(_not_loaded), do: nil

  defp build_filename([catalogue], date) do
    "#{sanitize_filename(catalogue.name)} #{date}.json"
  end

  defp build_filename(_, date), do: "Catalogues #{date}.json"

  defp sanitize_filename(name) when is_binary(name) do
    name
    # `u` flag keeps Unicode word chars (Cyrillic, etc.); without it `\w` is
    # ASCII-only and would strip a whole Cyrillic catalogue name.
    |> String.replace(~r/[^\w\s-]/u, "")
    |> String.replace(~r/\s+/, "_")
    |> String.trim("_")
  end

  defp sanitize_filename(_), do: "catalogue"
end
