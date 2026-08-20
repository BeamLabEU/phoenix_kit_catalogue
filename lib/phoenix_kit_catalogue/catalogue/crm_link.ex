defmodule PhoenixKitCatalogue.Catalogue.CrmLink do
  @moduledoc """
  The bridge between a catalogue directory row and the CRM party it projects.

  CRM is the party master: "supplier" and "manufacturer" are *roles* on a CRM
  company (see the CRM v2 parties design doc). The catalogue's local
  `phoenix_kit_cat_suppliers` / `phoenix_kit_cat_manufacturers` rows are not
  deleted by that move — they stay as the catalogue-side **projection**, for
  two concrete reasons:

    * catalogue-standalone installs have no CRM at all, and
    * `phoenix_kit_cat_items.manufacturer_uuid` is still a hard FK onto the
      local manufacturer row, so items keep pointing at the projection.

  `crm_company_uuid` (V149 for suppliers, V178 for manufacturers) is the
  transition cross-reference, one-to-one both ways via a partial unique index.

  ## What linking does, precisely

  1. grants the party role on the CRM company (idempotent), and
  2. copies the party's identity DOWN onto the local row.

  Step 2 is not redundant bookkeeping. Item lists, cards, search and every
  export render the preloaded local row — nothing on those paths calls a
  resolver — so a link that left the local name stale would show one name in
  the CRM directory and a different one on every product page. After linking,
  the local identity fields become read-only (enforced in the changesets, not
  just the forms) and `refresh/1` is the only way to update them.

  ## What linking does NOT do

  It does not migrate references. Items still reference the local manufacturer
  row, `phoenix_kit_cat_item_supplier_info.supplier_uuid` still holds whatever
  uuid it held, and warehouse documents still carry their local supplier
  uuids. Rewriting those to CRM uuids is a separate, guarded operation that is
  deliberately not part of this module — `Catalogue.get_supplier/1`, which
  warehouse calls, is a local primary-key lookup, so a rewrite would blank the
  supplier on posted documents.

  Every CRM call is guarded with `Code.ensure_loaded?` + `function_exported?`
  — CRM is an optional runtime dependency, and its absence is not an error.
  """

  alias PhoenixKitCatalogue.Catalogue.{ActivityLog, PubSub}
  alias PhoenixKitCatalogue.Schemas.{Manufacturer, Supplier}

  @type party :: %{
          uuid: Ecto.UUID.t(),
          name: String.t(),
          email: String.t() | nil,
          phone: String.t() | nil,
          website: String.t() | nil
        }

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc "True when the CRM module is loaded and exposes the party API this bridge needs."
  @spec available?() :: boolean()
  def available? do
    Code.ensure_loaded?(PhoenixKitCRM.Companies) and
      function_exported?(PhoenixKitCRM.Companies, :get_company, 1) and
      Code.ensure_loaded?(PhoenixKitCRM.PartyRoles) and
      function_exported?(PhoenixKitCRM.PartyRoles, :grant_role, 4)
  end

  @doc """
  CRM companies offered as link targets, as `{name, uuid}` pairs.

  Every company is a candidate, not only those already holding the role —
  linking is how a company *acquires* the role. Returns `[]` when CRM is
  absent.
  """
  @spec list_candidates() :: [{String.t(), Ecto.UUID.t()}]
  def list_candidates do
    if available?() and function_exported?(PhoenixKitCRM.Companies, :company_options, 0) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(PhoenixKitCRM.Companies, :company_options, [])
    else
      []
    end
  end

  @doc """
  Links a supplier to a CRM company: grants the `supplier` role and copies
  the party's identity onto the projection.

  Returns `{:error, :crm_unavailable}` when the CRM module is not installed,
  `{:error, :company_not_found}` for an unknown uuid, and a changeset error
  when the company is already linked to a different supplier (the partial
  unique index).
  """
  @spec link_supplier(Supplier.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Supplier.t()}
          | {:error, :crm_unavailable | :company_not_found | Ecto.Changeset.t()}
  def link_supplier(%Supplier{} = supplier, company_uuid, opts \\ []),
    do: link(supplier, company_uuid, "supplier", opts)

  @doc "Manufacturer counterpart of `link_supplier/3` — grants the `manufacturer` role."
  @spec link_manufacturer(Manufacturer.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Manufacturer.t()}
          | {:error, :crm_unavailable | :company_not_found | Ecto.Changeset.t()}
  def link_manufacturer(%Manufacturer{} = manufacturer, company_uuid, opts \\ []),
    do: link(manufacturer, company_uuid, "manufacturer", opts)

  defp link(record, company_uuid, role, opts) do
    with :ok <- ensure_available(),
         {:ok, company} <- fetch_company(company_uuid) do
      # Grant first: if the role grant fails we must not leave a projection
      # pointing at a party that does not carry the role, because the
      # resolvers key on the ACTIVE ROLE, not on the xref column.
      _ = grant_role(company, role)

      record
      |> link_changeset(%{
        crm_company_uuid: company.uuid,
        name: party_name(company),
        website: Map.get(company, :website),
        contact_info: contact_info_from(company)
      })
      |> repo().update()
      |> broadcast_and_log("linked", role, opts)
    end
  end

  @doc """
  Clears a supplier's CRM cross-reference, making its identity locally
  editable again.

  The party role is deliberately left in place: the company may be a supplier
  independently of whether this catalogue row projects it, and revoking a role
  from here would reach into CRM's own lifecycle.
  """
  @spec unlink_supplier(Supplier.t(), keyword()) ::
          {:ok, Supplier.t()} | {:error, Ecto.Changeset.t()}
  def unlink_supplier(%Supplier{} = supplier, opts \\ []), do: unlink(supplier, "supplier", opts)

  @doc "Manufacturer counterpart of `unlink_supplier/2`."
  @spec unlink_manufacturer(Manufacturer.t(), keyword()) ::
          {:ok, Manufacturer.t()} | {:error, Ecto.Changeset.t()}
  def unlink_manufacturer(%Manufacturer{} = manufacturer, opts \\ []),
    do: unlink(manufacturer, "manufacturer", opts)

  defp unlink(record, role, opts) do
    record
    |> link_changeset(%{crm_company_uuid: nil})
    |> repo().update()
    |> broadcast_and_log("unlinked", role, opts)
  end

  @doc """
  Re-copies the linked party's identity onto a supplier projection.

  The catalogue does not observe CRM writes (that would need a dependency in
  the wrong direction), so a party renamed in CRM leaves the projection —
  and therefore every item page — showing the old name until someone runs
  this. Returns `{:error, :not_linked}` for an unlinked row and
  `{:error, :party_not_found}` when the CRM company has since been deleted.
  """
  @spec refresh_supplier(Supplier.t(), keyword()) ::
          {:ok, Supplier.t()}
          | {:error, :not_linked | :crm_unavailable | :party_not_found | Ecto.Changeset.t()}
  def refresh_supplier(%Supplier{} = supplier, opts \\ []),
    do: refresh(supplier, "supplier", opts)

  @doc "Manufacturer counterpart of `refresh_supplier/2`."
  @spec refresh_manufacturer(Manufacturer.t(), keyword()) ::
          {:ok, Manufacturer.t()}
          | {:error, :not_linked | :crm_unavailable | :party_not_found | Ecto.Changeset.t()}
  def refresh_manufacturer(%Manufacturer{} = manufacturer, opts \\ []),
    do: refresh(manufacturer, "manufacturer", opts)

  defp refresh(%{crm_company_uuid: nil}, _role, _opts), do: {:error, :not_linked}

  defp refresh(record, role, opts) do
    with :ok <- ensure_available(),
         {:ok, company} <- fetch_party(record.crm_company_uuid) do
      record
      |> link_changeset(%{
        name: party_name(company),
        website: Map.get(company, :website),
        contact_info: contact_info_from(company)
      })
      |> repo().update()
      |> broadcast_and_log("refreshed", role, opts)
    end
  end

  # ── CRM access (all guarded) ───────────────────────────────────────────────

  defp ensure_available do
    if available?(), do: :ok, else: {:error, :crm_unavailable}
  end

  defp fetch_company(uuid) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    case apply(PhoenixKitCRM.Companies, :get_company, [uuid]) do
      nil -> {:error, :company_not_found}
      company -> {:ok, company}
    end
  end

  defp fetch_party(uuid) do
    case fetch_company(uuid) do
      {:ok, company} -> {:ok, company}
      {:error, :company_not_found} -> {:error, :party_not_found}
    end
  end

  defp grant_role(company, role) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(PhoenixKitCRM.PartyRoles, :grant_role, [company, role, %{}, []])
  rescue
    # A role grant that blows up must not take the link with it — the xref is
    # still correct and the role can be granted from the CRM side.
    _ -> :error
  catch
    :exit, _ -> :error
  end

  # ── Shared plumbing ────────────────────────────────────────────────────────

  defp link_changeset(%Supplier{} = supplier, attrs),
    do: Supplier.crm_link_changeset(supplier, attrs)

  defp link_changeset(%Manufacturer{} = manufacturer, attrs),
    do: Manufacturer.crm_link_changeset(manufacturer, attrs)

  # CRM companies carry structured email and phone; the catalogue projection
  # has one free-text "email or phone" column. Prefer the email.
  defp contact_info_from(company) do
    Map.get(company, :email) || Map.get(company, :phone)
  end

  defp party_name(company) do
    if Code.ensure_loaded?(PhoenixKitCRM.Schemas.Company) and
         function_exported?(PhoenixKitCRM.Schemas.Company, :display_name, 1) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(PhoenixKitCRM.Schemas.Company, :display_name, [company])
    else
      Map.get(company, :name)
    end
  end

  defp broadcast_and_log({:ok, record} = ok, action, role, opts) do
    ActivityLog.log(%{
      action: "#{role}.crm_#{action}",
      mode: "manual",
      actor_uuid: opts[:actor_uuid],
      resource_type: role,
      resource_uuid: record.uuid,
      metadata: %{
        "name" => record.name,
        "crm_company_uuid" => record.crm_company_uuid
      }
    })

    PubSub.broadcast(pubsub_kind(role), record.uuid)
    ok
  end

  defp broadcast_and_log(error, _action, _role, _opts), do: error

  defp pubsub_kind("supplier"), do: :supplier
  defp pubsub_kind("manufacturer"), do: :manufacturer
end
