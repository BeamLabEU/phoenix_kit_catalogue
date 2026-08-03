defmodule PhoenixKitCatalogue.Import.Pro100TemplatePlan do
  @moduledoc """
  Turns a parsed PRO100 estimate template into the catalogue structure to create.

  Pure — no database. The plan it returns is what the applier writes and what a
  dry run prints, so every judgement the load makes is inspectable before a row
  is touched.

  ## Three judgements this module makes, and why they are not obvious

  **Sub-headings.** The file has a second heading level it does not mark: a row
  with no price whose name introduces the priced rows after it (`-BLANCO`
  followed by twelve Blanco sorters; `HINGED` followed by fifteen hinges).
  Detection is `price == 0 AND (name starts with "-" OR name is all-caps)` — but
  **only among zero-price rows**. The same shape test over all 555 lines is
  useless: 68 dash-prefixed and 20 all-caps rows carry real prices
  (`-CARGO LISARIIULI KINNITUS,HALL = 19.10`). Confirmed against the real file
  and by the catalogue owner.

  **The one exception.** `-ARENA-CLASSIC RIIUL 40CM,VA/KR` matches the shape but
  is a product whose price is missing — its 30 cm sibling is priced at 56.02 in
  the same section. It is listed explicitly rather than handled by a cleverer
  rule, because every rule tried so far had counter-examples in both directions.
  The plan reports what it treated as a heading; a new export must be re-checked.

  **Prices carried in the name.** Two rows state their price in text and zero in
  the price column: `Kordusmõõtmine ( 60eu)`, `Prügivedu(85,00 EUR)`. Both are
  gross, like every other price in the file.

  Prices are gross throughout; `@vat_divisor` converts them. It is a named
  constant with the date it was valid because Estonia's rate has moved before.
  """

  alias PhoenixKitCatalogue.Import.Pro100TemplateParser, as: Parser

  # Estonian VAT, 24% as of 2026-07. Every Price in the export is gross.
  @vat_divisor Decimal.new("1.24")

  # Matches the sub-heading shape but is a real product: the same section prices
  # "-ARENA-CLASSIC RIIUL 30CM,VA/KR" at 56.02, so the 40 cm row is a variant
  # whose price is simply absent from the export.
  @not_a_heading ["-ARENA-CLASSIC RIIUL 40CM,VA/KR"]

  # The table whose computed row cannot live beside priced ones: in a smart
  # catalogue every item is priced from its rules, and an item with no rules
  # evaluates to 0.00 — measured. So the table is split, and the two priced
  # service lines stay in a standard catalogue.
  @computed_catalogue_suffix " (arvutuslik)"

  @type t :: %{
          folder: %{name: String.t()},
          catalogues: [catalogue()],
          headings: [%{catalogue: String.t(), section: String.t() | nil, name: String.t()}],
          price_from_name: [%{name: String.t(), gross: Decimal.t()}],
          stats: map()
        }

  @type catalogue :: %{
          name: String.t(),
          kind: String.t(),
          template_guid: String.t(),
          position: integer(),
          categories: [category()],
          items: [item()],
          rules: [rule()]
        }

  @type category :: %{name: String.t(), parent: String.t() | nil, position: integer()}
  @type item :: map()
  @type rule :: %{item_name: String.t(), referenced_catalogue: String.t(), value: Decimal.t(), unit: String.t()}

  @spec build([Parser.table()], keyword()) :: t()
  def build(tables, opts \\ []) do
    folder_name = Keyword.get(opts, :folder_name, "PRO100")

    {catalogues, headings, from_name} =
      tables
      |> Enum.reduce({[], [], []}, fn table, {cats, hs, fns} ->
        {built, h, f} = build_catalogue(table)
        {built ++ cats, h ++ hs, f ++ fns}
      end)

    # Standard catalogues first: a smart catalogue's rules reference standard
    # ones, so an applier walking this list in order never resolves a target
    # that does not exist yet.
    catalogues =
      catalogues
      |> Enum.reverse()
      |> Enum.sort_by(&(&1.kind == "smart"))
      |> Enum.with_index()
      |> Enum.map(fn {c, i} -> %{c | position: i} end)

    %{
      folder: %{name: folder_name},
      catalogues: catalogues,
      headings: Enum.reverse(headings),
      price_from_name: Enum.reverse(from_name),
      problems: problems(catalogues),
      stats: stats(catalogues, headings, from_name)
    }
  end

  @doc """
  Everything an applier must refuse to write. Empty means the plan is safe to
  apply; anything here is a defect in the export or in this module, not a row to
  skip quietly.
  """
  @spec problems([catalogue()]) :: [map()]
  def problems(catalogues) do
    names = MapSet.new(catalogues, & &1.name)
    kinds = Map.new(catalogues, &{&1.name, &1.kind})

    unresolved_targets =
      for c <- catalogues,
          r <- c.rules,
          not MapSet.member?(names, r.referenced_catalogue),
          do: %{kind: :rule_target_missing, catalogue: c.name, target: r.referenced_catalogue}

    # `Rules.validate_referenced_catalogue_kind/1` rejects a rule pointing at a
    # smart catalogue, and a smart target would contribute 0 to the sum anyway.
    smart_targets =
      for c <- catalogues,
          r <- c.rules,
          Map.get(kinds, r.referenced_catalogue) == "smart",
          do: %{kind: :rule_target_is_smart, catalogue: c.name, target: r.referenced_catalogue}

    duplicate_categories =
      for c <- catalogues,
          {key, n} <- Enum.frequencies_by(c.categories, &{&1.parent, &1.name}),
          n > 1,
          do: %{kind: :duplicate_category, catalogue: c.name, category: key}

    guids = catalogues |> Enum.flat_map(& &1.items) |> Enum.map(& &1.data["pro100"]["template_guid"])

    guid_problems =
      cond do
        Enum.any?(guids, &(&1 in [nil, ""])) -> [%{kind: :item_without_guid}]
        length(Enum.uniq(guids)) != length(guids) -> [%{kind: :duplicate_item_guid}]
        true -> []
      end

    unresolved_targets ++ smart_targets ++ duplicate_categories ++ guid_problems
  end

  # A table becomes one catalogue, except the one carrying a computed row: that
  # splits into a standard catalogue for the priced lines and a smart one for
  # the computed line alone.
  defp build_catalogue(table) do
    {headings, plain_with_category, from_name} = walk_lines(table)
    {computed, plain} = Enum.split_with(plain_with_category, &(&1.line.percentage != nil))

    categories = build_categories(table, headings)
    items = Enum.map(plain, &build_item/1)
    computed = Enum.map(computed, & &1.line)

    standard = %{
      name: table.name,
      kind: "standard",
      template_guid: table.template_guid,
      position: 0,
      categories: categories,
      items: items,
      rules: []
    }

    heading_report =
      Enum.map(headings, fn h -> %{catalogue: table.name, section: h.section, name: h.name} end)

    case computed do
      [] ->
        {[standard], heading_report, from_name}

      rows ->
        {[computed_catalogue(table, rows), standard], heading_report, from_name}
    end
  end

  defp computed_catalogue(table, rows) do
    %{
      name: table.name <> @computed_catalogue_suffix,
      kind: "smart",
      template_guid: table.template_guid <> ":computed",
      position: 0,
      categories: [],
      items: Enum.map(rows, &computed_item/1),
      rules:
        Enum.flat_map(rows, fn row ->
          Enum.map(row.sum_tables, fn target ->
            %{
              item_name: row.name,
              referenced_catalogue: target,
              value: row.percentage,
              unit: "percent"
            }
          end)
        end)
    }
  end

  defp computed_item(row) do
    %{
      name: row.name,
      base_price: nil,
      category: nil,
      position: row.sort_order,
      description: row.specification,
      data: %{
        "pro100" => %{
          "template_guid" => row.template_guid,
          "computed" => true,
          "percentage" => Decimal.to_string(row.percentage, :normal)
        }
      }
    }
  end

  # One ordered pass over the table's lines (the parser hands them back in
  # SortOrder). A sub-heading owns every line after it until the next
  # sub-heading or the end of its section — which is why this cannot be done by
  # filtering: the item→category link depends on position, not on content.
  defp walk_lines(table) do
    {headings, items, from_name, _} =
      Enum.reduce(table.lines, {[], [], [], {nil, nil}}, fn line, {hs, is, fns, {sec, sub}} ->
        sub = if line.section != sec, do: nil, else: sub

        if heading?(line) do
          h = %{name: clean_heading(line.name), section: line.section, raw: line.name}
          {[h | hs], is, fns, {line.section, h.name}}
        else
          {gross, recovered?, fns} = resolve_price(line, fns)

          # The category is carried as {parent_section, name}, never as a bare
          # name: two sub-headings under different sections, or a sub-heading
          # sharing a section's name, are distinct categories, and `Category`
          # has no unique constraint to catch a caller that conflates them.
          category = if sub, do: {line.section, sub}, else: {nil, line.section}

          entry = %{line: line, category: category, gross: gross, price_recovered: recovered?}
          {hs, [entry | is], fns, {line.section, sub}}
        end
      end)

    {Enum.reverse(headings), Enum.reverse(items), Enum.reverse(from_name)}
  end

  defp heading?(line) do
    zero_price?(line) and is_nil(line.percentage) and
      line.name not in @not_a_heading and
      (String.starts_with?(line.name, "-") or all_caps?(line.name))
  end

  defp zero_price?(%{gross_price: nil}), do: true
  defp zero_price?(%{gross_price: p}), do: Decimal.equal?(p, 0)

  defp all_caps?(name) do
    letters = name |> String.graphemes() |> Enum.filter(&String.match?(&1, ~r/\p{L}/u))
    letters != [] and Enum.all?(letters, &(String.upcase(&1) == &1))
  end

  # A heading's name becomes a category label, so the item-level "on request"
  # marker the file appends to some of them ("ALUMIINIUM RAAMID* päring") is
  # dropped: a category has no such state, and the stray asterisk reads as noise
  # in the tree.
  defp clean_heading(name) do
    name
    |> String.trim_leading("-")
    |> String.replace(~r/\s*\*?\s*päring\s*$/iu, "")
    |> String.trim()
  end

  # Sections become categories; sub-headings become their children. A line that
  # precedes any header in its table has no section at all — 44 of them.
  defp build_categories(table, headings) do
    sections =
      table.sections
      |> Enum.with_index()
      |> Enum.map(fn {name, i} -> %{name: name, parent: nil, position: i} end)

    subs =
      headings
      |> Enum.with_index()
      |> Enum.map(fn {h, i} -> %{name: h.name, parent: h.section, position: 1000 + i} end)

    sections ++ subs
  end

  defp build_item(%{line: line, category: category, gross: gross} = entry) do
    %{
      name: line.name,
      base_price: net(gross),
      category: category,
      position: line.sort_order,
      description: line.specification,
      data: %{
        "pro100" =>
          %{
            "template_guid" => line.template_guid,
            "gross_price" => gross && Decimal.to_string(gross, :normal)
          }
          |> maybe_flag(:price_on_request, is_nil(gross) or Decimal.equal?(gross, 0))
          |> maybe_flag(:price_recovered_from_name, Map.get(entry, :price_recovered, false))
      }
    }
  end

  # Deliberately narrow: the amount must sit in its own parentheses, which is how
  # both real rows write it — "Kordusmõõtmine ( 60eu)", "Prügivedu(85,00 EUR)".
  # An unanchored `<digits>eur` would also fire on an article code or a unit
  # price written into a name ("CARGO 150eur", "Toru 50 eur/m") and would then
  # write a wrong `base_price` with nothing on the item to say it was guessed.
  # Recovered prices are additionally flagged in `data["pro100"]`, so an item
  # priced this way says so.
  @price_in_name ~r/\(\s*(\d+(?:[.,]\d+)?)\s*eur?\s*\)/iu

  defp resolve_price(line, acc) do
    if zero_price?(line) do
      recover_price_from_name(line, acc)
    else
      {line.gross_price, false, acc}
    end
  end

  defp recover_price_from_name(line, acc) do
    with [_, captured] <- Regex.run(@price_in_name, line.name),
         {gross, _} <- captured |> String.replace(",", ".") |> Decimal.parse() do
      {gross, true, [%{name: line.name, gross: gross} | acc]}
    else
      _ -> {line.gross_price, false, acc}
    end
  end

  defp net(nil), do: nil

  defp net(gross) do
    if Decimal.equal?(gross, 0), do: gross, else: gross |> Decimal.div(@vat_divisor) |> Decimal.round(2)
  end

  defp maybe_flag(map, _key, false), do: map
  defp maybe_flag(map, key, true), do: Map.put(map, Atom.to_string(key), true)

  defp stats(catalogues, headings, from_name) do
    items = Enum.flat_map(catalogues, & &1.items)

    %{
      catalogues: length(catalogues),
      smart_catalogues: Enum.count(catalogues, &(&1.kind == "smart")),
      categories: catalogues |> Enum.flat_map(& &1.categories) |> length(),
      items: length(items),
      rules: catalogues |> Enum.flat_map(& &1.rules) |> length(),
      headings: length(headings),
      price_from_name: length(from_name),
      zero_price_items: Enum.count(items, &(is_nil(&1.base_price) or Decimal.equal?(&1.base_price, 0)))
    }
  end
end
