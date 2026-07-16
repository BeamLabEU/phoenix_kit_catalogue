defmodule PhoenixKitCRM.PartyRoles do
  @moduledoc """
  Minimal stand-in for `phoenix_kit_crm`'s `PartyRoles` context, compiled
  only under `MIX_ENV=test` (see `elixirc_paths/1` in mix.exs) so
  `PhoenixKitCatalogue.Catalogue.Suppliers`' CRM-guarded paths
  (`Code.ensure_loaded?/1` + `function_exported?/3`) have a real module to
  find. `phoenix_kit_crm` is not a dependency of this module — this fake
  exists purely to exercise the soft-dependency guard end to end,
  including the company/contact source-tagging that `list_all/1` relies on.

  Implements only the subset of `PhoenixKitCRM.PartyRoles`'s public
  contract that `Suppliers` actually calls: `get_supplier/1`,
  `list_companies_with_role/2`, `list_contacts_with_role/2`.
  """

  @companies [
    %{
      uuid: "11111111-1111-7111-8111-111111111111",
      name: "Acme Supply Co",
      email: "sales@acme.test",
      phone: "+1-555-0100",
      website: "https://acme.test"
    },
    %{
      uuid: "22222222-2222-7222-8222-222222222222",
      name: "",
      email: nil,
      phone: nil,
      website: nil
    }
  ]

  @contacts [
    %{
      uuid: "33333333-3333-7333-8333-333333333333",
      name: "Jane Rep",
      email: "jane@example.test",
      phone: "+1-555-0200"
    },
    %{
      uuid: "44444444-4444-7444-8444-444444444444",
      name: "",
      email: "anon@example.test",
      phone: nil
    }
  ]

  def get_supplier(uuid) do
    case Enum.find(@companies ++ @contacts, &(&1.uuid == uuid)) do
      nil -> nil
      party -> Map.put(party, :source, :crm)
    end
  end

  def list_companies_with_role("supplier", _opts), do: @companies
  def list_contacts_with_role("supplier", _opts), do: @contacts
end
