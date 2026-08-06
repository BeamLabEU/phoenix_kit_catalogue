defmodule PhoenixKitCatalogue.Import.Pro100TemplateTest do
  @moduledoc """
  Covers the pure half of the PRO100 estimate-template layer: the `configTables`
  parser and the plan built from it. `Pro100TemplateLoader` is not exercised here
  — it only talks to the database, so it belongs with the integration suite.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitCatalogue.Import.Pro100TemplateParser, as: Parser
  alias PhoenixKitCatalogue.Import.Pro100TemplatePlan, as: Plan

  # One table, in the shape the real export uses:
  #   * a section header ("Sektsioon:")
  #   * a zero-price sub-heading ("-BLANCO")
  #   * a dash-prefixed row that is a real product because it carries a price
  #   * a row whose price is only stated in its name
  #   * a computed row (Percentage + SumTables) that has to leave for a smart
  #     catalogue of its own
  #   * a blank-named row, which is counted and dropped
  # The computed row nests a full copy of the summed table; those rows must NOT
  # be read as products.
  @xml """
  <?xml version="1.0"?>
  <ArrayOfTable>
    <Table>
      <Name>Test Table</Name>
      <TemplateGuid>tbl-1</TemplateGuid>
      <Id>7</Id>
      <SortOrder>0</SortOrder>
      <Items>
        <TableItem>
          <Name>Sektsioon:</Name>
          <Price>0.00</Price>
          <TemplateGuid>g-sec</TemplateGuid>
          <SortOrder>1</SortOrder>
        </TableItem>
        <TableItem>
          <Name>-BLANCO</Name>
          <Price>0.00</Price>
          <TemplateGuid>g-sub</TemplateGuid>
          <SortOrder>2</SortOrder>
        </TableItem>
        <TableItem>
          <Name>-CARGO LISARIIUL,HALL</Name>
          <Price>24.80</Price>
          <TemplateGuid>g-cargo</TemplateGuid>
          <SortOrder>3</SortOrder>
          <Specification>Hall</Specification>
        </TableItem>
        <TableItem>
          <Name>Prügivedu(85,00 EUR)</Name>
          <Price>0.00</Price>
          <TemplateGuid>g-pruk</TemplateGuid>
          <SortOrder>4</SortOrder>
        </TableItem>
        <TableItem>
          <Name></Name>
          <Price>0.00</Price>
          <TemplateGuid>g-blank</TemplateGuid>
          <SortOrder>5</SortOrder>
        </TableItem>
        <TableItem>
          <Name>Paigaldus</Name>
          <Price>0.00</Price>
          <Percentage>10</Percentage>
          <TemplateGuid>g-calc</TemplateGuid>
          <SortOrder>6</SortOrder>
          <SumTables>
            <Table>
              <Name>Test Table</Name>
              <Items>
                <TableItem>
                  <Name>SNAPSHOT ROW</Name>
                  <Price>1.00</Price>
                  <TemplateGuid>g-snap</TemplateGuid>
                  <SortOrder>1</SortOrder>
                </TableItem>
              </Items>
            </Table>
          </SumTables>
        </TableItem>
      </Items>
    </Table>
  </ArrayOfTable>
  """

  defp tables, do: elem(Parser.parse(@xml), 1)

  describe "parser" do
    test "reads only Table/Items/TableItem, never the SumTables snapshots" do
      [table] = tables()

      names = Enum.map(table.lines, & &1.name)

      assert "SNAPSHOT ROW" not in names
      assert names == ["-BLANCO", "-CARGO LISARIIUL,HALL", "Prügivedu(85,00 EUR)", "Paigaldus"]
    end

    test "a trailing-colon row becomes a section and labels the rows after it" do
      [table] = tables()

      assert table.sections == ["Sektsioon"]
      assert Enum.all?(table.lines, &(&1.section == "Sektsioon"))
    end

    test "blank-named rows are counted and dropped" do
      assert [%{blank_count: 1}] = tables()
    end

    test "carries the table's own identity and the per-row scalars" do
      [table] = tables()

      assert table.name == "Test Table"
      assert table.template_guid == "tbl-1"
      assert table.id == "7"

      cargo = Enum.find(table.lines, &(&1.name == "-CARGO LISARIIUL,HALL"))
      assert Decimal.equal?(cargo.gross_price, Decimal.new("24.80"))
      assert cargo.specification == "Hall"
      assert cargo.sum_tables == []
    end

    test "a computed row keeps its percentage and its rule targets" do
      [table] = tables()

      calc = Enum.find(table.lines, &(&1.name == "Paigaldus"))
      assert Decimal.equal?(calc.percentage, Decimal.new("10"))
      assert calc.sum_tables == ["Test Table"]
    end

    test "rejects a root element that is not ArrayOfTable" do
      assert {:error, {:unexpected_root, "Nope"}} = Parser.parse("<Nope/>")
    end

    test "reports malformed XML rather than raising" do
      assert {:error, {:malformed_xml, _}} = Parser.parse("<ArrayOfTable>")
    end
  end

  describe "plan" do
    setup do
      %{plan: Plan.build(tables())}
    end

    test "a zero-price dash row is a sub-heading; a priced one is a product", %{plan: plan} do
      assert [%{name: "BLANCO", section: "Sektsioon"}] = plan.headings

      standard = Enum.find(plan.catalogues, &(&1.kind == "standard"))
      assert "-CARGO LISARIIUL,HALL" in Enum.map(standard.items, & &1.name)
      refute "-BLANCO" in Enum.map(standard.items, & &1.name)
    end

    test "sub-heading rows own the lines that follow them", %{plan: plan} do
      standard = Enum.find(plan.catalogues, &(&1.kind == "standard"))
      cargo = Enum.find(standard.items, &(&1.name == "-CARGO LISARIIUL,HALL"))

      assert cargo.category == {"Sektsioon", "BLANCO"}
      assert %{name: "BLANCO", parent: "Sektsioon"} = Enum.find(standard.categories, & &1.parent)
    end

    test "gross prices are converted to net", %{plan: plan} do
      standard = Enum.find(plan.catalogues, &(&1.kind == "standard"))
      cargo = Enum.find(standard.items, &(&1.name == "-CARGO LISARIIUL,HALL"))

      # 24.80 / 1.24
      assert Decimal.equal?(cargo.base_price, Decimal.new("20.00"))
      assert cargo.data["pro100"]["gross_price"] == "24.80"
    end

    test "a price stated only in the name is recovered and flagged", %{plan: plan} do
      standard = Enum.find(plan.catalogues, &(&1.kind == "standard"))
      pruk = Enum.find(standard.items, &(&1.name == "Prügivedu(85,00 EUR)"))

      assert Decimal.equal?(pruk.base_price, Decimal.new("68.55"))
      assert pruk.data["pro100"]["price_recovered_from_name"]
      assert [%{gross: gross}] = plan.price_from_name
      assert Decimal.equal?(gross, Decimal.new("85.00"))
    end

    test "the computed row leaves for a smart catalogue with a percent rule", %{plan: plan} do
      smart = Enum.find(plan.catalogues, &(&1.kind == "smart"))

      assert smart.name == "Test Table (arvutuslik)"
      assert [%{name: "Paigaldus"}] = smart.items
      assert [%{referenced_catalogue: "Test Table", unit: "percent", value: value}] = smart.rules
      assert Decimal.equal?(value, Decimal.new("10"))
    end

    test "standard catalogues are positioned before the smart ones that reference them",
         %{plan: plan} do
      assert Enum.map(plan.catalogues, & &1.kind) == ["standard", "smart"]
      assert Enum.map(plan.catalogues, & &1.position) == [0, 1]
    end

    test "a well-formed plan reports no problems", %{plan: plan} do
      assert plan.problems == []
    end

    test "an unresolvable rule target is a problem, not a silently dropped rule" do
      catalogues = [
        %{
          name: "Only",
          kind: "smart",
          template_guid: "g",
          position: 0,
          categories: [],
          items: [],
          rules: [
            %{
              item_name: "x",
              referenced_catalogue: "Missing",
              value: Decimal.new("1"),
              unit: "percent"
            }
          ]
        }
      ]

      assert [%{kind: :rule_target_missing, target: "Missing"}] = Plan.problems(catalogues)
    end

    test "stats account for every catalogue, item and rule", %{plan: plan} do
      assert plan.stats.catalogues == 2
      assert plan.stats.smart_catalogues == 1
      assert plan.stats.items == 3
      assert plan.stats.rules == 1
      assert plan.stats.headings == 1
      assert plan.stats.price_from_name == 1
    end
  end
end
