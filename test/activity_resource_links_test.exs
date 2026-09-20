defmodule PhoenixKitCatalogue.ActivityResourceLinksTest do
  @moduledoc """
  The Activity feed's way back to the record, and the `from`/`to` diff that
  says what an update actually changed.

  Both exist because the owner opened the activity log, clicked an event and
  could go no further: the Subject was a bare uuid and the metadata named the
  row rather than the change (boss via Max, 2026-09-20).
  """
  use ExUnit.Case, async: true

  alias PhoenixKitCatalogue.Catalogue.ActivityLog
  alias PhoenixKitCatalogue.Schemas.Item

  describe "resource_links/0" do
    test "every catalogue resource type a person can open has a path" do
      links = PhoenixKitCatalogue.resource_links()

      for type <- PhoenixKitCatalogue.record_link_types() do
        assert %{"path" => path, "title" => title} = links[type],
               "#{type} has no deep-link template"

        # Either the row's own uuid, or one it carries in metadata — a
        # supplier row links to its ITEM, not to the join row.
        assert String.contains?(path, ":uuid") or String.contains?(path, ":metadata."),
               "#{type}'s path identifies no record"

        assert String.starts_with?(path, "/admin/catalogue"), "#{type}'s path is not an admin one"
        assert String.starts_with?(title, ":metadata."), "#{type}'s title is not from metadata"
      end
    end

    test "paths are RAW — core applies the prefix and locale once at render" do
      for {_type, %{"path" => path}} <- record_templates() do
        refute String.starts_with?(path, "/phoenix_kit"),
               "#{path} is pre-prefixed and would double up"
      end
    end

    test "the supplier-comment resolver is still registered beside them" do
      links = PhoenixKitCatalogue.resource_links()
      type = PhoenixKitCatalogue.Catalogue.supplier_comment_resource_type()

      assert links[type] == PhoenixKitCatalogue,
             "the thread resolver must stay a module, not become a template"
    end

    defp record_templates do
      PhoenixKitCatalogue.resource_links()
      |> Map.take(PhoenixKitCatalogue.record_link_types())
    end
  end

  describe "changed_fields/3" do
    test "reports only what moved, as from/to" do
      before = %Item{name: "Hinge", sku: "H-1", unit: "pc"}
      now = %Item{name: "Soft-close hinge", sku: "H-1", unit: "pc"}

      assert ActivityLog.changed_fields(before, now, [:name, :sku, :unit]) ==
               %{"name" => %{"from" => "Hinge", "to" => "Soft-close hinge"}}
    end

    test "an untouched save logs no diff at all" do
      item = %Item{name: "Hinge", sku: "H-1"}
      assert ActivityLog.changed_fields(item, item, [:name, :sku]) == %{}
    end

    test "a decimal that only changed representation is not a change" do
      before = %Item{base_price: Decimal.new("8.50")}
      now = %Item{base_price: Decimal.new("8.5")}

      assert ActivityLog.changed_fields(before, now, [:base_price]) == %{}
    end

    test "a real price change reads as a plain number, not a Decimal struct" do
      before = %Item{base_price: Decimal.new("8.50")}
      now = %Item{base_price: Decimal.new("9.10")}

      assert ActivityLog.changed_fields(before, now, [:base_price]) ==
               %{"base_price" => %{"from" => "8.50", "to" => "9.10"}}
    end

    test "a value arriving or leaving reads as an empty side, never nil" do
      assert ActivityLog.changed_fields(%Item{sku: nil}, %Item{sku: "H-1"}, [:sku]) ==
               %{"sku" => %{"from" => "", "to" => "H-1"}}

      assert ActivityLog.changed_fields(%Item{sku: "H-1"}, %Item{sku: nil}, [:sku]) ==
               %{"sku" => %{"from" => "H-1", "to" => ""}}
    end

    test "the shape is the one core renders as old → new" do
      diff = ActivityLog.changed_fields(%Item{unit: "pc"}, %Item{unit: "m²"}, [:unit])

      assert PhoenixKit.Activity.humanize_metadata_value(diff["unit"]) == "pc → m²"
    end
  end

  describe "with_changes/4 — the reserved envelope" do
    # A rename used to overwrite the identity `"name"` with the diff MAP,
    # and the deep-link title (`:metadata.name` → `to_string/1`) then raised
    # Protocol.UndefinedError — so the one action most worth opening lost
    # its link. Found by the design panel, 2026-09-20.
    test "a rename keeps the identity name a string, with the diff beside it" do
      before = %Item{name: "T-Joint 22mm", sku: "T-22"}
      now = %Item{name: "T-Joint 25mm", sku: "T-22"}

      metadata =
        ActivityLog.with_changes(%{"name" => now.name, "sku" => now.sku}, before, now, [
          :name,
          :sku
        ])

      assert metadata["name"] == "T-Joint 25mm"
      assert is_binary(metadata["name"]), "the link title calls to_string/1 on this"

      assert metadata["changes"] == %{
               "name" => %{"from" => "T-Joint 22mm", "to" => "T-Joint 25mm"}
             }

      # what core's link template does with it, end to end
      assert to_string(Map.get(metadata, "name", "")) == "T-Joint 25mm"
    end

    test "nothing moved means no changes key at all" do
      item = %Item{name: "Hinge"}

      assert ActivityLog.with_changes(%{"name" => "Hinge"}, item, item, [:name]) == %{
               "name" => "Hinge"
             }
    end

    test "a long body records only that it changed, never both copies" do
      before = %Item{description: String.duplicate("a", 5_000)}
      now = %Item{description: String.duplicate("b", 5_000)}

      assert ActivityLog.changed_fields(before, now, [:description]) ==
               %{"description" => %{"changed" => true}}
    end

    test "an untouched description says nothing" do
      item = %Item{description: "same"}
      assert ActivityLog.changed_fields(item, item, [:description]) == %{}
    end
  end
end
