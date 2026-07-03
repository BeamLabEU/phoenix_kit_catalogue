defmodule PhoenixKitCatalogue.Pro100.IdTest do
  use ExUnit.Case, async: true
  alias PhoenixKitCatalogue.Pro100.Id

  test "keeps digits only" do
    assert Id.digits_only("76.0026.12") == "76002612"
    assert Id.digits_only("C-01") == "01"
  end

  test "nil and no-digit collapse to empty string" do
    assert Id.digits_only(nil) == ""
    assert Id.digits_only("abc") == ""
  end
end
