defmodule PhoenixKitCatalogue.SchemasTest do
  @moduledoc """
  Unit tests for all catalogue schema changesets. These are pure
  changeset validations — no DB round trip — so they run fast and
  cover every field-level constraint (required, length, inclusion,
  number range, etc.).
  """
  use ExUnit.Case, async: true

  alias PhoenixKitCatalogue.Schemas.{
    Catalogue,
    Category,
    Item,
    Manufacturer,
    Supplier
  }

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  # ═══════════════════════════════════════════════════════════════════
  # Catalogue
  # ═══════════════════════════════════════════════════════════════════

  describe "Catalogue.changeset/2" do
    test "accepts minimal valid attrs" do
      cs = Catalogue.changeset(%Catalogue{}, %{name: "Kitchen"})
      assert cs.valid?
    end

    test "requires name" do
      cs = Catalogue.changeset(%Catalogue{}, %{})
      refute cs.valid?
      assert %{name: ["can't be blank"]} = errors_on(cs)
    end

    test "rejects blank name" do
      cs = Catalogue.changeset(%Catalogue{}, %{name: ""})
      refute cs.valid?
    end

    test "rejects name over 255 chars" do
      cs = Catalogue.changeset(%Catalogue{}, %{name: String.duplicate("a", 256)})
      refute cs.valid?
      assert errors_on(cs)[:name]
    end

    test "accepts name exactly 255 chars" do
      cs = Catalogue.changeset(%Catalogue{}, %{name: String.duplicate("a", 255)})
      assert cs.valid?
    end

    test "rejects bogus status" do
      cs = Catalogue.changeset(%Catalogue{}, %{name: "x", status: "bogus"})
      refute cs.valid?
      assert errors_on(cs)[:status]
    end

    test "accepts all valid statuses" do
      for status <- ~w(active archived deleted) do
        cs = Catalogue.changeset(%Catalogue{}, %{name: "x", status: status})
        assert cs.valid?, "expected status #{status} to be valid"
      end
    end

    test "rejects negative markup_percentage" do
      cs = Catalogue.changeset(%Catalogue{}, %{name: "x", markup_percentage: -1})
      refute cs.valid?
      assert errors_on(cs)[:markup_percentage]
    end

    test "rejects markup_percentage over 1000" do
      cs = Catalogue.changeset(%Catalogue{}, %{name: "x", markup_percentage: 1001})
      refute cs.valid?
      assert errors_on(cs)[:markup_percentage]
    end

    test "accepts markup_percentage = 0 and = 1000" do
      for mp <- [0, 1000] do
        cs = Catalogue.changeset(%Catalogue{}, %{name: "x", markup_percentage: mp})
        assert cs.valid?, "expected markup_percentage=#{mp} to be valid"
      end
    end

    test "accepts decimal markup_percentage as string" do
      cs = Catalogue.changeset(%Catalogue{}, %{name: "x", markup_percentage: "15.50"})
      assert cs.valid?

      assert Decimal.equal?(
               Ecto.Changeset.get_field(cs, :markup_percentage),
               Decimal.new("15.50")
             )
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Category
  # ═══════════════════════════════════════════════════════════════════

  describe "Category.changeset/2" do
    @valid_catalogue_uuid "019d1330-c5e0-7caf-b84b-91a4418f67f2"

    test "accepts valid attrs" do
      cs =
        Category.changeset(%Category{}, %{
          name: "Frames",
          catalogue_uuid: @valid_catalogue_uuid
        })

      assert cs.valid?
    end

    test "requires name and catalogue_uuid" do
      cs = Category.changeset(%Category{}, %{})
      refute cs.valid?
      errors = errors_on(cs)
      assert errors[:name]
      assert errors[:catalogue_uuid]
    end

    test "rejects name over 255 chars" do
      cs =
        Category.changeset(%Category{}, %{
          name: String.duplicate("a", 256),
          catalogue_uuid: @valid_catalogue_uuid
        })

      refute cs.valid?
      assert errors_on(cs)[:name]
    end

    test "rejects bogus status" do
      cs =
        Category.changeset(%Category{}, %{
          name: "x",
          catalogue_uuid: @valid_catalogue_uuid,
          status: "bogus"
        })

      refute cs.valid?
      assert errors_on(cs)[:status]
    end

    test "accepts negative position (int field, no constraint)" do
      # Position is just an integer — the context controls ordering.
      cs =
        Category.changeset(%Category{}, %{
          name: "x",
          catalogue_uuid: @valid_catalogue_uuid,
          position: -1
        })

      assert cs.valid?
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Item
  # ═══════════════════════════════════════════════════════════════════

  describe "Item.changeset/2" do
    @valid_catalogue_uuid "019d1330-c5e0-7caf-b84b-91a4418f67f2"

    test "accepts minimal valid attrs" do
      cs = Item.changeset(%Item{}, %{name: "Panel", catalogue_uuid: @valid_catalogue_uuid})
      assert cs.valid?
    end

    test "requires name and catalogue_uuid" do
      cs = Item.changeset(%Item{}, %{})
      refute cs.valid?
      errors = errors_on(cs)
      assert errors[:name]
      assert errors[:catalogue_uuid]
    end

    test "rejects name over 255 chars" do
      cs =
        Item.changeset(%Item{}, %{
          name: String.duplicate("a", 256),
          catalogue_uuid: @valid_catalogue_uuid
        })

      refute cs.valid?
      assert errors_on(cs)[:name]
    end

    test "rejects sku over 100 chars" do
      cs =
        Item.changeset(%Item{}, %{
          name: "x",
          catalogue_uuid: @valid_catalogue_uuid,
          sku: String.duplicate("a", 101)
        })

      refute cs.valid?
      assert errors_on(cs)[:sku]
    end

    test "accepts sku exactly 100 chars" do
      cs =
        Item.changeset(%Item{}, %{
          name: "x",
          catalogue_uuid: @valid_catalogue_uuid,
          sku: String.duplicate("a", 100)
        })

      assert cs.valid?
    end

    test "rejects bogus status" do
      cs =
        Item.changeset(%Item{}, %{
          name: "x",
          catalogue_uuid: @valid_catalogue_uuid,
          status: "bogus"
        })

      refute cs.valid?
      assert errors_on(cs)[:status]
    end

    test "accepts every allowed status" do
      for status <- ~w(active inactive discontinued deleted) do
        cs =
          Item.changeset(%Item{}, %{
            name: "x",
            catalogue_uuid: @valid_catalogue_uuid,
            status: status
          })

        assert cs.valid?, "status #{status} should be valid"
      end
    end

    test "rejects bogus unit" do
      cs =
        Item.changeset(%Item{}, %{
          name: "x",
          catalogue_uuid: @valid_catalogue_uuid,
          unit: "bogus"
        })

      refute cs.valid?
      assert errors_on(cs)[:unit]
    end

    test "accepts every allowed unit" do
      for unit <- Item.allowed_units() do
        cs =
          Item.changeset(%Item{}, %{
            name: "x",
            catalogue_uuid: @valid_catalogue_uuid,
            unit: unit
          })

        assert cs.valid?, "unit #{unit} should be valid"
      end
    end

    test "rejects negative base_price" do
      cs =
        Item.changeset(%Item{}, %{
          name: "x",
          catalogue_uuid: @valid_catalogue_uuid,
          base_price: -1
        })

      refute cs.valid?
      assert errors_on(cs)[:base_price]
    end

    test "accepts zero base_price" do
      cs =
        Item.changeset(%Item{}, %{
          name: "x",
          catalogue_uuid: @valid_catalogue_uuid,
          base_price: 0
        })

      assert cs.valid?
    end

    test "accepts decimal base_price as string" do
      cs =
        Item.changeset(%Item{}, %{
          name: "x",
          catalogue_uuid: @valid_catalogue_uuid,
          base_price: "25.50"
        })

      assert cs.valid?
    end
  end

  describe "Item.sale_price/2" do
    test "returns nil when base_price is nil" do
      item = %Item{base_price: nil}
      assert Item.sale_price(item, Decimal.new("20")) == nil
    end

    test "returns base_price when markup is nil" do
      item = %Item{base_price: Decimal.new("100")}
      assert Decimal.equal?(Item.sale_price(item, nil), Decimal.new("100"))
    end

    test "computes markup correctly" do
      item = %Item{base_price: Decimal.new("100")}
      assert Decimal.equal?(Item.sale_price(item, Decimal.new("15")), Decimal.new("115.00"))
    end

    test "rounds to 2 decimal places" do
      item = %Item{base_price: Decimal.new("33.33")}
      result = Item.sale_price(item, Decimal.new("15"))
      # 33.33 * 1.15 = 38.3295 → rounds to 38.33
      assert Decimal.equal?(result, Decimal.new("38.33"))
    end

    test "handles zero markup" do
      item = %Item{base_price: Decimal.new("50")}
      assert Decimal.equal?(Item.sale_price(item, Decimal.new("0")), Decimal.new("50"))
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Manufacturer
  # ═══════════════════════════════════════════════════════════════════

  describe "Manufacturer.changeset/2" do
    test "accepts minimal valid attrs" do
      cs = Manufacturer.changeset(%Manufacturer{}, %{name: "Blum"})
      assert cs.valid?
    end

    test "requires name" do
      cs = Manufacturer.changeset(%Manufacturer{}, %{})
      refute cs.valid?
      assert errors_on(cs)[:name]
    end

    test "rejects long name/website/contact_info/logo_url" do
      too_long_name = String.duplicate("a", 256)
      too_long_500 = String.duplicate("b", 501)

      assert errors_on(Manufacturer.changeset(%Manufacturer{}, %{name: too_long_name}))[:name]

      cs =
        Manufacturer.changeset(%Manufacturer{}, %{
          name: "ok",
          website: too_long_500,
          contact_info: too_long_500,
          logo_url: too_long_500
        })

      refute cs.valid?
      errors = errors_on(cs)
      assert errors[:website]
      assert errors[:contact_info]
      assert errors[:logo_url]
    end

    test "only 'active' and 'inactive' statuses are allowed (no 'deleted')" do
      for status <- ~w(active inactive) do
        cs = Manufacturer.changeset(%Manufacturer{}, %{name: "x", status: status})
        assert cs.valid?
      end

      refute Manufacturer.changeset(%Manufacturer{}, %{name: "x", status: "deleted"}).valid?
      refute Manufacturer.changeset(%Manufacturer{}, %{name: "x", status: "bogus"}).valid?
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Supplier
  # ═══════════════════════════════════════════════════════════════════

  describe "Supplier.changeset/2" do
    test "accepts minimal valid attrs" do
      cs = Supplier.changeset(%Supplier{}, %{name: "DelCo"})
      assert cs.valid?
    end

    test "requires name" do
      cs = Supplier.changeset(%Supplier{}, %{})
      refute cs.valid?
      assert errors_on(cs)[:name]
    end

    test "rejects bogus status" do
      cs = Supplier.changeset(%Supplier{}, %{name: "x", status: "bogus"})
      refute cs.valid?
    end
  end
end
