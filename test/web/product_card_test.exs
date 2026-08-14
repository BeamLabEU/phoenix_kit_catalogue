defmodule PhoenixKitCatalogue.Web.Components.ProductCardTest do
  @moduledoc """
  Render-shape tests for the `product_card/1` function component and unit
  tests for its DB-free field extraction (`build_fields/2`). The DB-backed
  `resolve_images/1` folder listing + broken-featured filtering are covered
  in `product_card_db_test.exs`; here we pin the pure gallery render +
  hide-empty logic.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PhoenixKitCatalogue.Schemas.Item
  alias PhoenixKitCatalogue.Web.Components.ProductCard

  defp images do
    [
      %{uuid: "img-1", name: "front.jpg"},
      %{uuid: "img-2", name: "back.jpg"},
      %{uuid: "img-3", name: nil}
    ]
  end

  defp base_assigns(overrides) do
    Map.merge(
      %{
        id: "pc",
        show: true,
        target: nil,
        item_name: "Oak Panel",
        images: images(),
        current_image: "img-1",
        fields: [],
        on_close: "card_close"
      },
      overrides
    )
  end

  defp render_card(overrides \\ %{}) do
    render_component(&ProductCard.product_card/1, base_assigns(overrides))
  end

  describe "gallery" do
    test "shows the current image large (medium variant) and the item name as title" do
      html = render_card()

      assert html =~ "Oak Panel"
      # Main <img> resolves the current uuid at the medium variant.
      assert html =~ "img-1"
      assert html =~ "medium"
    end

    test "renders a thumbnail strip with a switch hook per image" do
      html = render_card()

      assert html =~ ~s(phx-click="card_select_image")
      assert html =~ ~s(phx-value-uuid="img-1")
      assert html =~ ~s(phx-value-uuid="img-2")
      assert html =~ ~s(phx-value-uuid="img-3")
    end

    test "highlights the current thumbnail" do
      # img-2 is current → its thumbnail gets the primary border.
      html = render_card(%{current_image: "img-2"})

      assert html =~ "border-primary"
      # The main image now resolves img-2.
      assert html =~ "img-2"
    end

    test "switching current_image changes the expanded image" do
      assert render_card(%{current_image: "img-1"}) =~ "img-1"
      assert render_card(%{current_image: "img-3"}) =~ "img-3"
    end

    test "a single image renders no thumbnail strip (nothing to switch to)" do
      html = render_card(%{images: [%{uuid: "only", name: "x.jpg"}], current_image: "only"})

      assert html =~ "only"
      refute html =~ ~s(phx-click="card_select_image")
    end
  end

  describe "fields" do
    test "renders the provided filled fields" do
      html = render_card(%{fields: [{"SKU", "KF-001"}, {"Price", "42.50"}]})

      assert html =~ "SKU"
      assert html =~ "KF-001"
      assert html =~ "Price"
      assert html =~ "42.50"
    end

    test "renders no field list when there are no fields" do
      html = render_card(%{fields: []})

      refute html =~ "<dl"
    end
  end

  describe "show=false" do
    test "renders nothing when closed" do
      html = render_card(%{show: false})

      refute html =~ "Oak Panel"
    end
  end

  describe "build_fields/2 (hide-empty logic)" do
    # Plain structs, no DB: sku/unit/description/metadata resolve purely;
    # price is rescued to nil when there's no catalogue to price against.
    test "includes filled scalar + metadata fields, keyed by their labels" do
      item = %Item{
        name: "Oak Panel",
        sku: "KF-001",
        unit: "running_meter",
        description: "Solid oak",
        catalogue: nil,
        base_price: nil,
        data: %{"meta" => %{"color" => "Natural", "material" => "Oak"}}
      }

      fields = ProductCard.build_fields(item, "en")

      assert {"SKU", "KF-001"} in fields
      assert {"Unit", "rm"} in fields
      assert {"Description", "Solid oak"} in fields
      assert {"Color", "Natural"} in fields
      assert {"Material", "Oak"} in fields
    end

    test "does not crash on a non-scalar metadata value (drops the bad metadata)" do
      # A malformed/legacy meta value that is itself a map makes
      # `Metadata.build_state/2` raise (it `to_string`s each value). build_fields
      # must swallow that and still return the scalar fields, never crash.
      item = %Item{
        name: "X",
        sku: "KF-1",
        unit: nil,
        description: nil,
        catalogue: nil,
        base_price: nil,
        data: %{"meta" => %{"color" => %{"nested" => "map"}}}
      }

      fields = ProductCard.build_fields(item, "en")

      assert is_list(fields)
      # The scalar SKU field still comes through; the bad metadata is dropped.
      assert {"SKU", "KF-1"} in fields
      refute Enum.any?(fields, fn {label, _value} -> label == "Color" end)
    end

    test "drops empty fields entirely" do
      item = %Item{
        name: "Bare",
        sku: nil,
        unit: nil,
        description: "",
        catalogue: nil,
        base_price: nil,
        data: %{}
      }

      labels = item |> ProductCard.build_fields("en") |> Enum.map(&elem(&1, 0))

      refute "SKU" in labels
      refute "Description" in labels
      refute "Unit" in labels
    end
  end
end
