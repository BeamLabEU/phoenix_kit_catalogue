defmodule PhoenixKitCatalogue.Import.Pro100TemplateParser do
  @moduledoc """
  Parses a PRO100 `configTables` export — the estimate/price template PRO100 uses
  to quote a project. XML, despite the extension the exporter gives it.

  Shape: `ArrayOfTable` → `Table` → `Items/TableItem`. Three things about that
  structure are easy to get wrong and each was measured against the real export
  (`Pro100doc_configTables_2026-07-15_192106`, 10 tables / 708 rows):

    * **Only `Table/Items/TableItem` are rows.** The same file serialises 584 of
      them twice more, under `TableItem/SumTables/Table` and
      `CalculatedItem/SumTables/Table` — snapshots of the summed tables, not
      products. A `//TableItem` sweep yields 1876 rows instead of 708.

    * **…but the nested `SumTables/Table/Name` list is still needed.** It is where
      a computed row's rule targets come from, and it lives inside the branch
      whose *rows* are ignored.

    * **A row's table comes from the XML nesting, never from `TableId`.**
      `TableId` is `0` on 707 of 708 rows; only the computed row carries a real
      one. (`TableGuid` is a valid alternative — it equals the parent table's
      `TemplateGuid` on every row — but nesting is what we already have.)

  Sections are implicit: a row whose `Name` ends with `:` is a header for the rows
  after it in `SortOrder` order. 44 lines precede any header in their table and
  belong to no section.

  Prices in the file are **gross**; converting them is the caller's business —
  this module reports what the file says.
  """

  @type line :: %{
          name: String.t(),
          section: String.t() | nil,
          gross_price: Decimal.t() | nil,
          template_guid: String.t(),
          sort_order: integer(),
          specification: String.t() | nil,
          percentage: Decimal.t() | nil,
          sum_tables: [String.t()]
        }

  @type table :: %{
          name: String.t(),
          template_guid: String.t(),
          id: String.t(),
          sort_order: integer(),
          sections: [String.t()],
          lines: [line()],
          blank_count: non_neg_integer()
        }

  @doc """
  Parses the export into `{:ok, [table()]}`.

  Blank-named rows are counted (`:blank_count`) and dropped; header rows become
  `:sections` and set the `:section` of the lines that follow them.
  """
  @spec parse(binary()) :: {:ok, [table()]} | {:error, term()}
  def parse(xml) when is_binary(xml) do
    case Saxy.SimpleForm.parse_string(xml, expand_entity: :never) do
      {:ok, {"ArrayOfTable", _attrs, children}} ->
        {:ok, children |> elements("Table") |> Enum.map(&build_table/1)}

      {:ok, {other, _, _}} ->
        {:error, {:unexpected_root, other}}

      {:error, reason} ->
        {:error, {:malformed_xml, reason}}
    end
  end

  defp build_table({_tag, _attrs, children}) do
    fields = scalar_fields(children)

    {lines, sections, blanks} =
      children
      |> elements("Items")
      |> Enum.flat_map(fn {_, _, items} -> elements(items, "TableItem") end)
      |> Enum.sort_by(&(&1 |> row_fields() |> Map.get("SortOrder") |> to_int()))
      |> Enum.reduce({[], [], 0}, &classify_row/2)

    %{
      name: Map.get(fields, "Name", ""),
      template_guid: Map.get(fields, "TemplateGuid", ""),
      id: Map.get(fields, "Id", ""),
      sort_order: fields |> Map.get("SortOrder") |> to_int(),
      sections: Enum.reverse(sections),
      lines: Enum.reverse(lines),
      blank_count: blanks
    }
  end

  defp classify_row(row, {lines, sections, blanks}) do
    fields = row_fields(row)
    name = fields |> Map.get("Name", "") |> String.trim()

    cond do
      name == "" ->
        {lines, sections, blanks + 1}

      String.ends_with?(name, ":") ->
        {lines, [name |> String.trim_trailing(":") |> String.trim() | sections], blanks}

      true ->
        {[build_line(fields, row, List.first(sections), name) | lines], sections, blanks}
    end
  end

  defp build_line(fields, row, section, name) do
    %{
      name: name,
      section: section,
      gross_price: fields |> Map.get("Price") |> to_decimal(),
      template_guid: Map.get(fields, "TemplateGuid", ""),
      sort_order: fields |> Map.get("SortOrder") |> to_int(),
      specification: fields |> Map.get("Specification") |> blank_to_nil(),
      percentage: fields |> Map.get("Percentage") |> to_decimal(),
      sum_tables: sum_table_names(row)
    }
  end

  # The rule targets of a computed row: the NAMES of the nested SumTables tables.
  # Their own `Items/TableItem` children are deliberately never read.
  defp sum_table_names({_tag, _attrs, children}) do
    children
    |> elements("SumTables")
    |> Enum.flat_map(fn {_, _, sums} -> elements(sums, "Table") end)
    |> Enum.map(fn {_, _, sub} -> sub |> scalar_fields() |> Map.get("Name", "") end)
    |> Enum.reject(&(&1 == ""))
  end

  defp row_fields({_tag, _attrs, children}), do: scalar_fields(children)

  # ── Saxy simple-form helpers ─────────────────────────────────────

  defp elements(children, tag) do
    for {^tag, _attrs, _sub} = el <- children, do: el
  end

  # Direct children that hold no elements of their own -> %{"Field" => "text"}.
  defp scalar_fields(children) do
    for {tag, _attrs, sub} <- children,
        not Enum.any?(sub, &is_tuple/1),
        into: %{} do
      {tag, sub |> Enum.filter(&is_binary/1) |> Enum.join() |> String.trim()}
    end
  end

  defp to_int(nil), do: 0

  defp to_int(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp to_decimal(nil), do: nil
  defp to_decimal(""), do: nil

  defp to_decimal(str) do
    case str |> String.replace(",", ".") |> Decimal.parse() do
      {d, _} -> d
      :error -> nil
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(str), do: str
end
