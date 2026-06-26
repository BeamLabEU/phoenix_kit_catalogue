defmodule PhoenixKitCatalogue.Export.UniversalJson do
  @moduledoc """
  Universal JSON export encoder.

  Produces a generic, source-agnostic JSON dump of catalogue items.
  Used by `PhoenixKitCatalogue.Export.Pro100` for its `:json` format,
  but also callable directly from any other source.

  ## Output shape

      {
        "catalogue": {"uuid": "...", "name": "..."},
        "category":  {"uuid": "...", "name": "..."},  // null if whole catalogue
        "exported_at": "2026-06-26T16:00:00Z",
        "index": 1111111111,
        "items": [
          {"name": "...", "sku": "...", "base_price": "2222.00", "unit": "piece", "category": "..."}
        ]
      }
  """

  alias PhoenixKitCatalogue.Export.Pro100

  @doc """
  Renders the universal JSON export.

  `ctx` must have keys: `:items`, `:index`, `:catalogue`, `:category`
  (`:category` may be `nil` for a whole-catalogue export).

  Returns `{filename, iodata, mime_type}`.
  """
  def render(ctx) do
    %{items: items, index: index, catalogue: catalogue, category: category} = ctx

    payload = %{
      "catalogue" => %{"uuid" => catalogue.uuid, "name" => catalogue.name},
      "category" => encode_category(category),
      "exported_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "index" => index,
      "items" => Enum.map(items, &encode_item/1)
    }

    filename = "#{sanitize_filename(catalogue.name)}.json"
    json = Jason.encode!(payload, pretty: true)
    {filename, json, "application/json"}
  end

  defp encode_category(nil), do: nil

  defp encode_category(category),
    do: %{"uuid" => category.uuid, "name" => category.name}

  defp encode_item(item) do
    category_name =
      case item.category do
        %{name: name} -> name
        _ -> nil
      end

    %{
      "name" => item.name,
      "sku" => item.sku,
      "base_price" => Pro100.format_price(item.base_price),
      "unit" => item.unit,
      "category" => category_name
    }
  end

  defp sanitize_filename(name) when is_binary(name) do
    name
    |> String.replace(~r/[^\w\s-]/, "")
    |> String.replace(~r/\s+/, "_")
    |> String.trim("_")
  end

  defp sanitize_filename(_), do: "catalogue"
end
