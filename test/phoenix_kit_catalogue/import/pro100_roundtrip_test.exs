defmodule PhoenixKitCatalogue.Import.Pro100RoundtripTest do
  use ExUnit.Case, async: true
  alias PhoenixKitCatalogue.Export.Pro100
  alias PhoenixKitCatalogue.Import.Pro100Parser

  defp fixture(name),
    do: File.read!(Path.join([__DIR__, "..", "..", "support", "fixtures", "pro100", name]))

  # Rebuild item maps from parsed rows the way Pro100Plan would persist them.
  defp to_item(row) do
    %{
      name: row.name,
      sku: row.id,
      base_price: row.base_price,
      unit: "piece",
      catalogue: nil,
      data: %{"pro100" => Map.put(row.service, "format", Atom.to_string(row.format))}
    }
  end

  test "furniture round-trips byte-identically except the header index" do
    original = fixture("furniture_8.txt")
    {:ok, rows} = Pro100Parser.parse(original, :furniture)
    items = Enum.map(rows, &to_item/1)

    {_name, iodata, _mime} =
      Pro100.render(:furniture, %{
        items: items,
        index: 1_111_111_111,
        catalogues: [],
        prefix_catalogue: false
      })

    produced = IO.iodata_to_binary(iodata)

    # Compare body (everything after the first CRLF) byte-for-byte.
    body = fn bin -> bin |> String.split("\r\n", parts: 2) |> List.last() end
    # Strip BOM from the original for the body comparison.
    original_nobom = String.replace_prefix(original, <<0xEF, 0xBB, 0xBF>>, "")
    assert body.(produced) == body.(original_nobom)
  end
end
