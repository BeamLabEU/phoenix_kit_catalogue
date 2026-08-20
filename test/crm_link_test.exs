defmodule PhoenixKitCatalogue.CrmLinkTest do
  @moduledoc """
  The catalogue side of the CRM party bridge.

  The CRM module is deliberately NOT a dependency of this package (the
  cross-module rule is a guarded soft dep, no mix dep in either direction),
  so the CRM-present half of `CrmLink` cannot run here — it is exercised on
  an install that has both. What this file pins is everything that must hold
  regardless: graceful degradation when CRM is absent, the projection's
  write rules, and the picker de-duplication that the linked state produces.
  """

  use PhoenixKitCatalogue.DataCase, async: true

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.{CrmLink, Manufacturers, Suppliers}
  alias PhoenixKitCatalogue.Schemas.{Manufacturer, Supplier}

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

  # Linking normally goes through CrmLink, which needs CRM loaded. These tests
  # need only the RESULTING state, so they write the xref straight in — the
  # same way a linked row looks after the bridge has run.
  defp mark_linked!(record) do
    record
    |> Ecto.Changeset.change(%{crm_company_uuid: Ecto.UUID.generate()})
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
      supplier = supplier_fixture()

      assert {:error, :crm_unavailable} =
               CrmLink.link_supplier(supplier, Ecto.UUID.generate())
    end

    test "refreshing an unlinked row reports :not_linked before it ever reaches CRM" do
      assert {:error, :not_linked} = CrmLink.refresh_supplier(supplier_fixture())
      assert {:error, :not_linked} = CrmLink.refresh_manufacturer(manufacturer_fixture())
    end

    test "refreshing a linked row reports :crm_unavailable" do
      supplier = supplier_fixture() |> mark_linked!()

      assert {:error, :crm_unavailable} = CrmLink.refresh_supplier(supplier)
    end

    test "unlinking works without CRM — it only clears local state" do
      supplier = supplier_fixture() |> mark_linked!()

      assert {:ok, unlinked} = CrmLink.unlink_supplier(supplier)
      assert unlinked.crm_company_uuid == nil
    end
  end

  describe "the projection's write rules" do
    test "an unlinked supplier's identity is freely editable" do
      supplier = supplier_fixture()

      assert {:ok, updated} = Catalogue.update_supplier(supplier, %{name: "Renamed Locally"})
      assert updated.name == "Renamed Locally"
    end

    test "a linked supplier refuses identity edits through the ordinary changeset" do
      supplier = supplier_fixture() |> mark_linked!()

      assert {:error, changeset} = Catalogue.update_supplier(supplier, %{name: "Sneaky Rename"})
      assert "is managed in CRM for a linked supplier" in errors_on(changeset).name
    end

    test "a linked supplier still accepts catalogue-local edits" do
      supplier = supplier_fixture() |> mark_linked!()

      assert {:ok, updated} =
               Catalogue.update_supplier(supplier, %{status: "inactive", notes: "on hold"})

      assert updated.status == "inactive"
      assert updated.notes == "on hold"
    end

    test "a linked manufacturer refuses identity edits but keeps logo_url editable" do
      manufacturer = manufacturer_fixture() |> mark_linked!()

      assert {:error, changeset} =
               Catalogue.update_manufacturer(manufacturer, %{website: "https://evil.example"})

      assert "is managed in CRM for a linked manufacturer" in errors_on(changeset).website

      assert {:ok, updated} =
               Catalogue.update_manufacturer(manufacturer, %{logo_url: "https://cdn/logo.png"})

      assert updated.logo_url == "https://cdn/logo.png"
    end

    test "crm_link_changeset/2 is the write path that IS allowed to set identity" do
      supplier = supplier_fixture() |> mark_linked!()

      changeset = Supplier.crm_link_changeset(supplier, %{name: "Name From CRM"})

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :name) == "Name From CRM"
    end

    test "the supplier form cannot set the cross-reference itself" do
      supplier = supplier_fixture()

      {:ok, updated} =
        Catalogue.update_supplier(supplier, %{crm_company_uuid: Ecto.UUID.generate()})

      assert updated.crm_company_uuid == nil
    end
  end

  describe "one party, one projection (the partial unique index)" do
    test "two suppliers cannot claim the same CRM company" do
      party_uuid = Ecto.UUID.generate()
      first = supplier_fixture()
      second = supplier_fixture()

      {:ok, _} =
        first |> Supplier.crm_link_changeset(%{crm_company_uuid: party_uuid}) |> repo_update()

      assert {:error, changeset} =
               second
               |> Supplier.crm_link_changeset(%{crm_company_uuid: party_uuid})
               |> repo_update()

      assert "is already linked to another supplier" in errors_on(changeset).crm_company_uuid
    end

    test "two manufacturers cannot claim the same CRM company" do
      party_uuid = Ecto.UUID.generate()

      {:ok, _} =
        manufacturer_fixture()
        |> Manufacturer.crm_link_changeset(%{crm_company_uuid: party_uuid})
        |> repo_update()

      assert {:error, changeset} =
               manufacturer_fixture()
               |> Manufacturer.crm_link_changeset(%{crm_company_uuid: party_uuid})
               |> repo_update()

      assert "is already linked to another manufacturer" in errors_on(changeset).crm_company_uuid
    end

    test "many rows may stay unlinked — the index is partial, not total" do
      supplier_fixture()
      supplier_fixture()
      supplier_fixture()

      assert length(Suppliers.list_suppliers()) >= 3
    end

    test "a supplier and a manufacturer MAY project the same party" do
      party_uuid = Ecto.UUID.generate()

      assert {:ok, _} =
               supplier_fixture()
               |> Supplier.crm_link_changeset(%{crm_company_uuid: party_uuid})
               |> repo_update()

      assert {:ok, _} =
               manufacturer_fixture()
               |> Manufacturer.crm_link_changeset(%{crm_company_uuid: party_uuid})
               |> repo_update()
    end
  end

  describe "list_all/1 de-duplication" do
    test "an unlinked local supplier is listed" do
      supplier = supplier_fixture()

      assert Enum.any?(Suppliers.list_all(), &(&1.uuid == supplier.uuid))
    end

    test "a LINKED local supplier is omitted — the CRM party represents it instead" do
      supplier = supplier_fixture() |> mark_linked!()

      refute Enum.any?(Suppliers.list_all(), &(&1.uuid == supplier.uuid))
    end

    test "a linked local manufacturer is omitted from list_all/1 too" do
      manufacturer = manufacturer_fixture() |> mark_linked!()

      refute Enum.any?(Manufacturers.list_all(), &(&1.uuid == manufacturer.uuid))
    end

    test "the omitted projection stays resolvable by uuid — items still reference it" do
      supplier = supplier_fixture(%{name: "Projected Co"}) |> mark_linked!()

      assert {:ok, resolved} = Suppliers.resolve(supplier.uuid)
      assert resolved.name == "Projected Co"
      assert resolved.source == :local
    end
  end

  describe "Manufacturers.resolve/1 with no CRM present" do
    test "resolves a local manufacturer" do
      manufacturer = manufacturer_fixture(%{name: "Acme Tools", website: "https://acme.example"})

      assert {:ok, resolved} = Manufacturers.resolve(manufacturer.uuid)
      assert resolved.name == "Acme Tools"
      assert resolved.website == "https://acme.example"
      assert resolved.source == :local
    end

    test "returns :error for an unknown uuid" do
      assert Manufacturers.resolve(Ecto.UUID.generate()) == :error
    end

    test "the facade exposes it under the cross-module name" do
      manufacturer = manufacturer_fixture()

      assert {:ok, _} = Catalogue.resolve_manufacturer(manufacturer.uuid)
      assert is_list(Catalogue.list_all_manufacturers())
    end
  end

  defp repo_update(changeset), do: PhoenixKit.RepoHelper.repo().update(changeset)
end
