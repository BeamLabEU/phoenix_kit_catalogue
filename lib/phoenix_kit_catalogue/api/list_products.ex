defmodule PhoenixKitCatalogue.API.ListProducts do
  @moduledoc false
  # Tool `catalogue.list_products`.

  alias PhoenixKitCatalogue.API
  alias PhoenixKitCatalogue.API.{Common, Presenter}
  alias PhoenixKitCatalogue.Catalogue

  @max_limit 100
  @default_limit 20

  @spec call(map(), map()) :: {:ok, map()} | {:error, atom(), String.t(), map()}
  def call(input, ctx) do
    with {:ok, catalogue} <- API.resolve_catalogue(input["catalogue_id"]),
         {:ok, category_uuid} <- Common.parse_uuid(input["category_id"], "category_id"),
         {:ok, updated_since} <- parse_since(input["updated_since"]),
         {:ok, cursor} <- parse_cursor(input["cursor"]),
         {:ok, dimensions} <- parse_dimensions(input) do
      {limit, warnings} = limit(input["limit"])
      fields = input["fields"] || Presenter.default_list_fields()

      opts = [
        catalogue_uuid: catalogue.uuid,
        category_uuid: category_uuid,
        status: input["status"],
        include_deleted: input["include_deleted"] == true,
        updated_since: updated_since,
        q: input["q"],
        dimensions: dimensions,
        cursor: cursor,
        limit: limit
      ]

      %{items: items, next_cursor: next_cursor} = Catalogue.list_items_keyset(opts)
      extras = Presenter.extras(items, fields, ctx)

      body = %{
        "items" => Enum.map(items, &Presenter.item(&1, fields, extras)),
        "next_cursor" => next_cursor,
        "count" => Catalogue.count_items_matching(opts)
      }

      {:ok,
       Common.with_warnings(
         body,
         warnings ++ Presenter.warnings(fields, extras, is_list(input["fields"]))
       )}
    end
  end

  defp parse_since(nil), do: {:ok, nil}

  defp parse_since(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} ->
        {:ok, at}

      {:error, _reason} ->
        Common.invalid(
          "updated_since",
          "must be an ISO 8601 date-time with a zone, for example 2026-10-01T00:00:00Z"
        )
    end
  end

  # `<dimension>_min` / `<dimension>_max`, inclusive; the same value in both
  # is an exact match. A JSON number or a decimal string.
  defp parse_dimensions(input) do
    Enum.reduce_while(~w(length_mm width_mm thickness_mm), {:ok, %{}}, fn field, {:ok, acc} ->
      with {:ok, min} <- parse_bound(input, field <> "_min"),
           {:ok, max} <- parse_bound(input, field <> "_max") do
        {:cont, {:ok, Map.put(acc, field, {min, max})}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp parse_bound(input, key) do
    case input[key] do
      nil -> {:ok, nil}
      n when is_integer(n) -> {:ok, Decimal.new(n)}
      n when is_float(n) -> {:ok, Decimal.from_float(n)}
      text when is_binary(text) -> parse_bound_text(text, key)
    end
  end

  defp parse_bound_text(text, key) do
    case Decimal.parse(String.trim(text)) do
      {%Decimal{coef: coef} = decimal, ""} when is_integer(coef) -> {:ok, decimal}
      _other -> Common.invalid(key, "must be a number, for example 18 or \"6.5\"")
    end
  end

  defp parse_cursor(nil), do: {:ok, nil}

  defp parse_cursor(value) do
    case Catalogue.decode_items_cursor(value) do
      {:ok, cursor} -> {:ok, cursor}
      :error -> Common.invalid("cursor", "is not a cursor this endpoint issued")
    end
  end

  # A soft over-limit is trimmed with a warning; the schema only
  # refuses a limit below 1.
  defp limit(nil), do: {@default_limit, []}
  defp limit(n) when n <= @max_limit, do: {n, []}

  defp limit(_n) do
    {@max_limit,
     [
       %{
         "code" => "limit_trimmed",
         "message" => "limit was trimmed to #{@max_limit}.",
         "limit" => @max_limit
       }
     ]}
  end
end
