defmodule PhoenixKitCatalogue.CrmLinkTest do
  @moduledoc """
  The catalogue side of the CRM party bridge, after the move to live
  resolution.

  The CRM module is deliberately NOT a dependency of this package (guarded soft
  dep, no mix dep either way), so the CRM-present half runs on an install that
  has both. What this file pins is everything that must hold regardless — and
  in particular the behaviour when CRM is ABSENT, which is where the previous
  version was silently wrong.
  """

  use PhoenixKitCatalogue.DataCase, async: true

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.{CrmLink, Manufacturers, Suppliers}

  defp supplier_fixture(attrs \\ %{}) do
    {:ok, s} =
      Catalogue.create_supplier(
        Map.merge(%{name: "Local Supplier #{System.unique_integer([:positive])}"}, attrs)
      )

    s
  end

  defp manufacturer_fixture(attrs \\ %{}) do
    {:ok, m} =
      Catalogue.create_manufacturer(
        Map.merge(%{name: "Local Maker #{System.unique_integer([:positive])}"}, attrs)
      )

    m
  end

  # A linked row, as the bridge would leave it: the xref stamped and NOTHING
  # else touched — no identity copied down.
  defp mark_linked!(record, party_uuid \\ nil) do
    record
    |> Ecto.Changeset.change(%{crm_company_uuid: party_uuid || Ecto.UUID.generate()})
    |> PhoenixKit.RepoHelper.repo().update!()
  end

  describe "when the CRM module is absent" do
    test "available?/0 reports false rather than raising" do
      refute CrmLink.available?()
    end

    test "list_candidates/0 returns an empty list, so a picker renders empty not broken" do
      assert CrmLink.list_candidates() == []
    end

    test "linking fails with :crm_unavailable instead of crashing" do
      assert {:error, :crm_unavailable} =
               CrmLink.link_supplier(supplier_fixture(), Ecto.UUID.generate())
    end

    test "unlinking works without CRM — it only clears local state" do
      supplier = supplier_fixture() |> mark_linked!()

      assert {:ok, unlinked} = CrmLink.unlink_supplier(supplier)
      assert unlinked.crm_company_uuid == nil
    end

    test "unlinking an already-unlinked row is a no-op, not an error" do
      assert {:ok, _} = CrmLink.unlink_supplier(supplier_fixture())
    end
  end

  describe "a linked row stays visible when its party cannot be resolved" do
    # This is the defect the previous version shipped: it rejected EVERY row
    # carrying an xref, whether or not the party came back. With CRM absent —
    # a supported install — every linked supplier vanished from every picker
    # with no error anywhere.

    test "list_all/1 still lists a linked supplier when CRM is not installed" do
      supplier = supplier_fixture() |> mark_linked!()

      assert Enum.any?(Suppliers.list_all(), &(&1.uuid == supplier.uuid))
    end

    test "list_all/1 still lists a linked manufacturer when CRM is not installed" do
      manufacturer = manufacturer_fixture() |> mark_linked!()

      assert Enum.any?(Manufacturers.list_all(), &(&1.uuid == manufacturer.uuid))
    end

    test "resolve/1 falls back to the local row when the party is unreachable" do
      supplier = supplier_fixture(%{name: "Fallback Co"}) |> mark_linked!()

      assert {:ok, resolved} = Suppliers.resolve(supplier.uuid)
      assert resolved.name == "Fallback Co"
      assert resolved.source == :local
    end

    test "the same holds for manufacturers" do
      manufacturer = manufacturer_fixture(%{name: "Fallback Maker"}) |> mark_linked!()

      assert {:ok, resolved} = Manufacturers.resolve(manufacturer.uuid)
      assert resolved.name == "Fallback Maker"
    end
  end

  describe "linking copies nothing" do
    test "the schemas no longer expose a changeset that writes party identity" do
      refute function_exported?(PhoenixKitCatalogue.Schemas.Supplier, :crm_link_changeset, 2)
      refute function_exported?(PhoenixKitCatalogue.Schemas.Manufacturer, :crm_link_changeset, 2)
    end

    test "there is no refresh action left to call — nothing is cached to refresh" do
      refute function_exported?(CrmLink, :refresh_supplier, 2)
      refute function_exported?(CrmLink, :refresh_manufacturer, 2)
    end

    test "a linked row's own identity stays editable — it is no longer authoritative" do
      supplier = supplier_fixture() |> mark_linked!()

      assert {:ok, updated} = Catalogue.update_supplier(supplier, %{name: "Renamed Locally"})
      assert updated.name == "Renamed Locally"
    end

    test "the supplier form still cannot set the cross-reference itself" do
      supplier = supplier_fixture()

      {:ok, updated} =
        Catalogue.update_supplier(supplier, %{crm_company_uuid: Ecto.UUID.generate()})

      assert updated.crm_company_uuid == nil
    end
  end

  describe "stale writes are refused rather than applied" do
    test "unlinking with a struct whose xref has since changed reports :stale" do
      supplier = supplier_fixture() |> mark_linked!()
      stale = supplier

      # Someone else re-links the row to a different party.
      _ = mark_linked!(supplier, Ecto.UUID.generate())

      assert {:error, :stale} = CrmLink.unlink_supplier(stale)
    end

    test "a successful unlink reports the cleared record" do
      supplier = supplier_fixture() |> mark_linked!()

      assert {:ok, cleared} = CrmLink.unlink_supplier(supplier)
      assert cleared.crm_company_uuid == nil
      assert Catalogue.get_supplier(supplier.uuid).crm_company_uuid == nil
    end
  end

  describe "resolve_many/1" do
    test "resolves a batch of local rows" do
      a = supplier_fixture(%{name: "Batch A"})
      b = supplier_fixture(%{name: "Batch B"})

      resolved = Suppliers.resolve_many([a.uuid, b.uuid])

      assert resolved[a.uuid].name == "Batch A"
      assert resolved[b.uuid].name == "Batch B"
    end

    test "omits uuids that resolve to nothing rather than inventing an entry" do
      unknown = Ecto.UUID.generate()

      assert Suppliers.resolve_many([unknown]) == %{}
    end

    test "tolerates an empty list, nils and duplicates" do
      a = manufacturer_fixture()

      assert Manufacturers.resolve_many([]) == %{}
      assert Map.has_key?(Manufacturers.resolve_many([a.uuid, a.uuid, nil]), a.uuid)
    end

    test "agrees with resolve/1 on every uuid it returns" do
      a = supplier_fixture(%{name: "Agreement Co"})
      batch = Suppliers.resolve_many([a.uuid])

      assert {:ok, single} = Suppliers.resolve(a.uuid)
      assert batch[a.uuid] == single
    end

    test "the facade exposes both batch resolvers" do
      s = supplier_fixture()
      m = manufacturer_fixture()

      assert Map.has_key?(Catalogue.resolve_suppliers([s.uuid]), s.uuid)
      assert Map.has_key?(Catalogue.resolve_manufacturers([m.uuid]), m.uuid)
    end
  end

  describe "one party, one projection (the partial unique index)" do
    test "two suppliers cannot both claim the same CRM company" do
      party = Ecto.UUID.generate()
      _first = supplier_fixture() |> mark_linked!(party)
      second = supplier_fixture()

      assert_raise Ecto.ConstraintError, fn -> mark_linked!(second, party) end
    end

    test "a supplier and a manufacturer MAY represent the same party" do
      party = Ecto.UUID.generate()

      assert %{} = supplier_fixture() |> mark_linked!(party)
      assert %{} = manufacturer_fixture() |> mark_linked!(party)
    end

    test "many rows may stay unlinked — the index is partial, not total" do
      supplier_fixture()
      supplier_fixture()

      assert length(Suppliers.list_suppliers()) >= 2
    end
  end

  describe "normalize_candidates/1" do
    # Found on a live install: CRM returns `%{label:, value:}`, the panel
    # matched `{name, uuid}`, and a comprehension DROPS non-matching elements —
    # so the picker rendered with zero options and no error anywhere.
    test "normalizes the map shape CRM actually returns" do
      assert [{"Acme", "01a0-uuid"}] =
               CrmLink.normalize_candidates([%{label: "Acme", value: "01a0-uuid"}])
    end

    test "accepts the tuple shape and drops anything unrecognized" do
      assert [{"Acme", "01a0-uuid"}] = CrmLink.normalize_candidates([{"Acme", "01a0-uuid"}])

      assert [] =
               CrmLink.normalize_candidates([
                 :garbage,
                 nil,
                 %{name: "no value key"},
                 %{label: "nil value", value: nil},
                 {"nil value", nil}
               ])
    end
  end

  describe "an item's manufacturer is a federated reference (V179)" do
    alias PhoenixKitCatalogue.Schemas.Item

    defp item_fixture(manufacturer_attrs) do
      {:ok, c} = Catalogue.create_catalogue(%{name: "Cat #{System.unique_integer([:positive])}"})

      {:ok, item} =
        Catalogue.create_item(
          Map.merge(%{name: "Widget", catalogue_uuid: c.uuid}, manufacturer_attrs)
        )

      item
    end

    test "Item carries no :manufacturer association to preload" do
      refute :manufacturer in Item.__schema__(:associations)
    end

    test "the source defaults to local" do
      m = manufacturer_fixture()
      item = item_fixture(%{manufacturer_uuid: m.uuid})

      assert item.manufacturer_source == "local"
    end

    test "an unknown source is refused" do
      m = manufacturer_fixture()

      assert {:error, changeset} =
               Catalogue.create_item(%{
                 name: "Bad",
                 catalogue_uuid: item_fixture(%{}).catalogue_uuid,
                 manufacturer_uuid: m.uuid,
                 manufacturer_source: "wishful"
               })

      assert %{manufacturer_source: _} = errors_on(changeset)
    end

    test "a CRM-sourced uuid can be stored — the FK that forbade it is gone" do
      party = Ecto.UUID.generate()

      item =
        item_fixture(%{
          manufacturer_uuid: party,
          manufacturer_source: "crm_company",
          manufacturer_name_snapshot: "Party Co"
        })

      assert item.manufacturer_uuid == party
      assert item.manufacturer_source == "crm_company"
    end

    test "hydrate/1 stamps the resolved name onto the virtual field" do
      m = manufacturer_fixture(%{name: "Hydrated Co"})
      item = item_fixture(%{manufacturer_uuid: m.uuid})

      assert [hydrated] = Manufacturers.hydrate([item])
      assert hydrated.manufacturer_name == "Hydrated Co"
    end

    test "hydrate/1 falls back to the snapshot when the reference resolves to nothing" do
      item =
        item_fixture(%{
          manufacturer_uuid: Ecto.UUID.generate(),
          manufacturer_source: "crm_company",
          manufacturer_name_snapshot: "Deleted Party"
        })

      assert [hydrated] = Manufacturers.hydrate([item])
      assert hydrated.manufacturer_name == "Deleted Party"
    end

    test "hydrate/1 leaves an item with no manufacturer alone" do
      item = item_fixture(%{})

      assert [hydrated] = Manufacturers.hydrate([item])
      assert hydrated.manufacturer_name == nil
    end

    test "hydrate/1 accepts a single item as well as a list" do
      m = manufacturer_fixture(%{name: "Single"})
      item = item_fixture(%{manufacturer_uuid: m.uuid})

      assert %Item{manufacturer_name: "Single"} = Manufacturers.hydrate(item)
    end

    test "the list queries hydrate without the caller asking" do
      m = manufacturer_fixture(%{name: "Auto Hydrated"})
      item = item_fixture(%{manufacturer_uuid: m.uuid})

      listed = Enum.find(Catalogue.list_items(), &(&1.uuid == item.uuid))
      assert listed.manufacturer_name == "Auto Hydrated"
    end

    test "a linked manufacturer resolves through to its party name for items too" do
      # No CRM here, so the party is unreachable and it falls back to the local
      # row — the fallback path that keeps product pages readable.
      m = manufacturer_fixture(%{name: "Projected Maker"}) |> mark_linked!()
      item = item_fixture(%{manufacturer_uuid: m.uuid})

      assert [hydrated] = Manufacturers.hydrate([item])
      assert hydrated.manufacturer_name == "Projected Maker"
    end
  end

  describe "what a CRM party supplies / manufactures" do
    # Powers the Catalogue tab on the company page in CRM. Since the catalogue
    # no longer has supplier or manufacturer pages, that tab is the only place
    # "what do they actually supply?" can be answered.

    defp catalogue_item(name) do
      {:ok, c} = Catalogue.create_catalogue(%{name: "Cat #{System.unique_integer([:positive])}"})
      {:ok, item} = Catalogue.create_item(%{name: name, catalogue_uuid: c.uuid})
      item
    end

    test "finds sourcing recorded against the party's own uuid" do
      party = Ecto.UUID.generate()
      item = catalogue_item("Direct Party Item")

      {:ok, _} =
        Catalogue.create_supplier_info(%{
          item_uuid: item.uuid,
          supplier_uuid: party,
          supplier_source: "crm_company",
          unit_cost: Decimal.new("9.50"),
          currency: "EUR",
          is_primary: true
        })

      # Returns Item structs so the catalogue's own table can render them --
      # image column, card view and all -- rather than a bespoke row shape.
      assert [row] = Catalogue.items_supplied_by(party)
      assert row.uuid == item.uuid
      assert row.name == "Direct Party Item"
      assert %Ecto.Association.NotLoaded{} != row.catalogue
    end

    test "ALSO finds sourcing recorded against a local row that projects the party" do
      party = Ecto.UUID.generate()
      supplier = supplier_fixture() |> mark_linked!(party)
      item = catalogue_item("Legacy Reference Item")

      {:ok, _} =
        Catalogue.create_supplier_info(%{
          item_uuid: item.uuid,
          supplier_uuid: supplier.uuid,
          supplier_source: "local",
          unit_cost: Decimal.new("3.00"),
          currency: "EUR"
        })

      assert [row] = Catalogue.items_supplied_by(party)
      assert row.name == "Legacy Reference Item"
    end

    test "excludes closed sourcing rows" do
      party = Ecto.UUID.generate()
      item = catalogue_item("Closed Row Item")

      {:ok, info} =
        Catalogue.create_supplier_info(%{
          item_uuid: item.uuid,
          supplier_uuid: party,
          supplier_source: "crm_company",
          unit_cost: Decimal.new("1.00"),
          currency: "EUR"
        })

      {:ok, _} = Catalogue.update_supplier_info(info, %{valid_to: Date.utc_today()})

      assert Catalogue.items_supplied_by(party) == []
    end

    test "finds items manufactured directly and through a linked local row" do
      party = Ecto.UUID.generate()
      maker = manufacturer_fixture() |> mark_linked!(party)

      {:ok, c} = Catalogue.create_catalogue(%{name: "MCat #{System.unique_integer([:positive])}"})

      {:ok, _direct} =
        Catalogue.create_item(%{
          name: "Direct",
          catalogue_uuid: c.uuid,
          manufacturer_uuid: party,
          manufacturer_source: "crm_company"
        })

      {:ok, _via_local} =
        Catalogue.create_item(%{
          name: "Via Local",
          catalogue_uuid: c.uuid,
          manufacturer_uuid: maker.uuid
        })

      rows = Catalogue.items_manufactured_by(party)

      assert rows |> Enum.map(& &1.name) |> Enum.sort() == ["Direct", "Via Local"]

      # Hydrated, so the manufacturer column has something to render. The
      # CRM-sourced one resolves to nothing here (no CRM installed) and falls
      # back to its snapshot, which this fixture never set — that nil IS the
      # tombstone path working.
      via_local = Enum.find(rows, &(&1.name == "Via Local"))
      assert via_local.manufacturer_name == maker.name
    end

    test "returns nothing for a party with no catalogue presence, and tolerates junk" do
      assert Catalogue.items_supplied_by(Ecto.UUID.generate()) == []
      assert Catalogue.items_manufactured_by(Ecto.UUID.generate()) == []
      assert Catalogue.items_supplied_by(nil) == []
      assert Catalogue.items_manufactured_by(nil) == []
    end
  end
end
