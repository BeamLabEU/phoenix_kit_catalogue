defmodule PhoenixKitCatalogue.Web.SizeFilter do
  @moduledoc """
  The catalogue detail page's size filter: a from–to range per item
  dimension, kept in the URL (`?size=`) so a filtered list is a link.

  The URL value is `t:12-18,l:2500-,w:-1250` — `l`, `w`, `t` for
  `length_mm`, `width_mm`, `thickness_mm`, each with an optional lower and
  upper bound in millimetres, inclusive. It is client-forgeable, so
  `decode/1` keeps only the parts it can read and drops the rest; an
  unreadable filter is no filter, never an error.

  `to_dimensions/1` is the shape `Catalogue.filter_by_dimensions/2` takes.
  """

  @keys [{"l", :length_mm}, {"w", :width_mm}, {"t", :thickness_mm}]
  @number ~S"\d{1,7}(?:\.\d{1,3})?"
  @part Regex.compile!("^([lwt]):(#{@number})?-(#{@number})?$")

  @type bounds :: {Decimal.t() | nil, Decimal.t() | nil}
  @type t :: %{optional(:length_mm | :width_mm | :thickness_mm) => bounds()}

  @doc "The dimensions the filter covers, in the order the form shows them."
  @spec fields() :: [atom()]
  def fields, do: Enum.map(@keys, &elem(&1, 1))

  @doc "Reads a `?size=` value. Anything unreadable is left out."
  @spec decode(term()) :: t()
  def decode(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.reduce(%{}, fn part, acc ->
      case Regex.run(@part, part, capture: :all_but_first) do
        [key | bounds] -> put_bounds(acc, field(key), bounds)
        nil -> acc
      end
    end)
  end

  def decode(_other), do: %{}

  @doc "The `?size=` value of a filter; `\"\"` for none."
  @spec encode(t()) :: String.t()
  def encode(filter) do
    for {key, field} <- @keys, {min, max} <- [Map.get(filter, field)], min || max do
      "#{key}:#{text(min)}-#{text(max)}"
    end
    |> Enum.join(",")
  end

  @doc """
  The filter typed into the form — `%{"thickness_mm" => %{"min" => "12",
  "max" => "18"}, …}`. A comma decimal is read as a dot; a value that is
  not a number in range, or anything else in the payload, is left out.
  """
  @spec from_params(term()) :: t()
  def from_params(params) when is_map(params) do
    Enum.reduce(@keys, %{}, fn {_key, field}, acc ->
      case Map.get(params, Atom.to_string(field)) do
        %{} = row -> put_bounds(acc, field, [typed(row["min"]), typed(row["max"])])
        _other -> acc
      end
    end)
  end

  def from_params(_other), do: %{}

  @doc "What `Catalogue.filter_by_dimensions/2` takes as `:dimensions`."
  @spec to_dimensions(t()) :: map()
  def to_dimensions(filter), do: filter

  @doc "How many dimensions have a rule."
  @spec active(t()) :: non_neg_integer()
  def active(filter), do: map_size(filter)

  @doc "A bound as the form's input shows it; `\"\"` when open."
  @spec input_value(t(), atom(), :min | :max) :: String.t()
  def input_value(filter, field, side) do
    case Map.get(filter, field) do
      {min, _max} when side == :min -> text(min)
      {_min, max} when side == :max -> text(max)
      nil -> ""
    end
  end

  defp field(key), do: @keys |> List.keyfind(key, 0) |> elem(1)

  defp put_bounds(acc, field, [min, max]) do
    case {number(min), number(max)} do
      {nil, nil} -> acc
      bounds -> Map.put(acc, field, bounds)
    end
  end

  # `Regex.run/3` leaves trailing empty captures out: "t:12-" answers one
  # bound and "t:-" none.
  defp put_bounds(acc, field, [min]), do: put_bounds(acc, field, [min, nil])
  defp put_bounds(acc, _field, []), do: acc

  defp typed(value) when is_binary(value), do: value |> String.trim() |> String.replace(",", ".")
  defp typed(_other), do: nil

  defp number(value) when is_binary(value) do
    if Regex.match?(~r/^#{@number}$/, value), do: Decimal.new(value), else: nil
  end

  defp number(_other), do: nil

  defp text(nil), do: ""
  defp text(%Decimal{} = value), do: value |> Decimal.normalize() |> Decimal.to_string(:normal)
end
