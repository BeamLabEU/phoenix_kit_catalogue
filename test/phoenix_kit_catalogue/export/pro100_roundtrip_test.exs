defmodule PhoenixKitCatalogue.Export.Pro100RoundtripTest do
  use ExUnit.Case, async: true
  alias PhoenixKitCatalogue.Export.Pro100

  defp ctx(items),
    do: %{items: items, index: 1_111_111_111, catalogues: [], prefix_catalogue: false}

  test "furniture emits stored service columns instead of constants" do
    item = %{
      name: "Second 1 furniture 222",
      sku: "1111",
      base_price: Decimal.new("2222.00"),
      unit: "piece",
      catalogue: nil,
      data: %{
        "pro100" => %{
          "format" => "furniture",
          "c3" => "0",
          "c5" => "1.0",
          "c6" => "222.00",
          "c7" => "1.0"
        }
      }
    }

    {_name, iodata, _mime} = Pro100.render(:furniture, ctx([item]))
    text = IO.iodata_to_binary(iodata)
    assert text =~ "\t\tSecond 1 furniture 222\t1111\t0\t2222.00\t1.0\t222.00\t1.0\r\n"
  end

  test "item without pro100 data falls back to today's constants" do
    item = %{
      name: "Plain",
      sku: "W-9",
      base_price: Decimal.new("5.00"),
      unit: "piece",
      catalogue: nil,
      data: %{}
    }

    {_n, iodata, _m} = Pro100.render(:furniture, ctx([item]))
    text = IO.iodata_to_binary(iodata)
    assert text =~ "\t\tPlain\t9\t0\t5.00\t1.0\t\t0.0\r\n"
  end
end
