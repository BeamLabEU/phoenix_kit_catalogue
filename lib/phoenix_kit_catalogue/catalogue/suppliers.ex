defmodule PhoenixKitCatalogue.Catalogue.Suppliers do
  @moduledoc """
  Suppliers — delivery companies linked to manufacturers via the
  many-to-many `phoenix_kit_cat_manufacturer_suppliers` table.

  Same lifecycle as manufacturers: hard-delete only, `"active"` /
  `"inactive"` status.

  ### Cross-module supplier resolution

  `resolve/1` and `list_all/1` provide a unified view of suppliers across
  sources (local `cat_suppliers` + CRM when available). CRM access is
  guarded via `Code.ensure_loaded?` / `function_exported?` — the CRM module
  is an optional runtime dependency and may not be present.

  Public surface is re-exported from `PhoenixKitCatalogue.Catalogue`.
  """

  import Ecto.Query, warn: false

  alias PhoenixKitCatalogue.Catalogue.{ActivityLog, ItemSupplierInfos, PubSub}
  alias PhoenixKitCatalogue.Schemas.Supplier

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc """
  Lists all suppliers, ordered by name.

  ## Options

    * `:status` — filter by status (e.g. `"active"`, `"inactive"`).
  """
  @spec list_suppliers(keyword()) :: [Supplier.t()]
  def list_suppliers(opts \\ []) do
    query = from(s in Supplier, order_by: [asc: :name])

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status -> where(query, [s], s.status == ^status)
      end

    repo().all(query)
  end

  @doc "Fetches a supplier by UUID. Returns `nil` if not found."
  @spec get_supplier(Ecto.UUID.t()) :: Supplier.t() | nil
  def get_supplier(uuid), do: repo().get(Supplier, uuid)

  @doc "Fetches a supplier by UUID. Raises `Ecto.NoResultsError` if not found."
  @spec get_supplier!(Ecto.UUID.t()) :: Supplier.t()
  def get_supplier!(uuid), do: repo().get!(Supplier, uuid)

  @doc """
  Creates a supplier.

  ## Required attributes

    * `:name` — supplier name (1-255 chars)

  ## Optional attributes

    * `:description`, `:website`, `:contact_info`, `:notes`
    * `:status` — `"active"` (default) or `"inactive"`
    * `:data` — flexible JSON map
  """
  @spec create_supplier(map(), keyword()) ::
          {:ok, Supplier.t()} | {:error, Ecto.Changeset.t(Supplier.t())}
  def create_supplier(attrs, opts \\ []) do
    result =
      ActivityLog.with_log(
        fn -> %Supplier{} |> Supplier.changeset(attrs) |> repo().insert() end,
        fn supplier ->
          %{
            action: "supplier.created",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "supplier",
            resource_uuid: supplier.uuid,
            metadata: %{"name" => supplier.name}
          }
        end
      )

    with {:ok, supplier} <- result do
      PubSub.broadcast(:supplier, supplier.uuid)
      {:ok, supplier}
    end
  end

  @doc "Updates a supplier with the given attributes."
  @spec update_supplier(Supplier.t(), map(), keyword()) ::
          {:ok, Supplier.t()} | {:error, Ecto.Changeset.t(Supplier.t())}
  def update_supplier(%Supplier{} = supplier, attrs, opts \\ []) do
    result =
      ActivityLog.with_log(
        fn -> supplier |> Supplier.changeset(attrs) |> repo().update() end,
        fn updated ->
          %{
            action: "supplier.updated",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "supplier",
            resource_uuid: updated.uuid,
            metadata: %{"name" => updated.name}
          }
        end
      )

    with {:ok, updated} <- result do
      PubSub.broadcast(:supplier, updated.uuid)
      {:ok, updated}
    end
  end

  @doc "Hard-deletes a supplier from the database."
  @spec delete_supplier(Supplier.t(), keyword()) ::
          {:ok, Supplier.t()} | {:error, Ecto.Changeset.t(Supplier.t())}
  def delete_supplier(%Supplier{} = supplier, opts \\ []) do
    result =
      ActivityLog.with_log(
        fn -> repo().delete(supplier) end,
        fn _ ->
          %{
            action: "supplier.deleted",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "supplier",
            resource_uuid: supplier.uuid,
            metadata: %{"name" => supplier.name}
          }
        end
      )

    with {:ok, deleted} <- result do
      PubSub.broadcast(:supplier, supplier.uuid)
      {:ok, deleted}
    end
  end

  @doc "Returns a changeset for tracking supplier changes."
  @spec change_supplier(Supplier.t(), map()) :: Ecto.Changeset.t(Supplier.t())
  def change_supplier(%Supplier{} = supplier, attrs \\ %{}) do
    Supplier.changeset(supplier, attrs)
  end

  @doc """
  Resolves a supplier UUID to a unified map regardless of source.

  Returns `{:ok, map}` with keys `:uuid`, `:name`, `:email`, `:phone`,
  `:website`, `:source` (`:crm | :local`), or `:error` when the supplier
  cannot be found in any source.

  The CRM branch reports the generic `:crm` tag rather than
  `:crm_company` / `:crm_contact` — `PhoenixKitCRM.PartyRoles.get_supplier/1`
  resolves either roleable type in one call but its return shape doesn't
  say which; `list_all/1` (backed by per-type role listings) is the
  source for the more specific tags used elsewhere in this module.

  CRM lookup is guarded — when `PhoenixKitCRM.PartyRoles` is not loaded
  (the CRM module is an optional runtime dependency), the CRM path is
  skipped and only local suppliers are checked.
  """
  @spec resolve(Ecto.UUID.t()) :: {:ok, map()} | :error
  def resolve(uuid) when is_binary(uuid) do
    with :error <- try_resolve_crm(uuid) do
      case repo().get(Supplier, uuid) do
        nil ->
          :error

        %Supplier{} = s ->
          {:ok,
           %{
             uuid: s.uuid,
             name: s.name,
             email: nil,
             phone: nil,
             website: s.website,
             source: :local
           }}
      end
    end
  end

  @doc """
  Lists all suppliers from all available sources as normalized maps.

  Each entry has keys `:uuid`, `:name`, `:email`, `:phone`, `:website`,
  `:source` (`:crm_company | :crm_contact | :local`). CRM companies then
  CRM contacts are listed first (when available), then local suppliers
  ordered by name.

  CRM access is guarded — when `PhoenixKitCRM.PartyRoles` is not loaded,
  only local suppliers are returned.
  """
  @spec list_all(keyword()) :: [map()]
  def list_all(opts \\ []) do
    crm_suppliers = list_crm_suppliers()

    local_suppliers =
      list_suppliers(opts)
      |> Enum.map(fn s ->
        %{
          uuid: s.uuid,
          name: s.name,
          email: nil,
          phone: nil,
          website: s.website,
          source: :local
        }
      end)

    crm_suppliers ++ local_suppliers
  end

  @doc "Returns the primary supplier-info row for an item, or `nil` if none is marked primary."
  @spec primary_for_item(Ecto.UUID.t()) :: PhoenixKitCatalogue.Schemas.ItemSupplierInfo.t() | nil
  def primary_for_item(item_uuid), do: ItemSupplierInfos.primary_for_item(item_uuid)

  @doc """
  Returns the *current* junction row for an item/supplier pair, or `nil`.

  "Current" means `valid_to` is `nil`. This is the function warehouse calls
  to check whether a receipt line's unit price diverges from the catalogued
  cost for the same supplier.
  """
  @spec active_info_for(Ecto.UUID.t(), Ecto.UUID.t()) ::
          PhoenixKitCatalogue.Schemas.ItemSupplierInfo.t() | nil
  def active_info_for(item_uuid, supplier_uuid) do
    import Ecto.Query, warn: false

    from(i in PhoenixKitCatalogue.Schemas.ItemSupplierInfo,
      where:
        i.item_uuid == ^item_uuid and i.supplier_uuid == ^supplier_uuid and is_nil(i.valid_to),
      limit: 1
    )
    |> repo().one()
  end

  @doc """
  Delegates to `ItemSupplierInfos.revise_unit_cost/3`.

  This is the stable public surface that warehouse and other consumers should
  call. See `ItemSupplierInfos.revise_unit_cost/3` for full documentation.
  """
  @spec revise_unit_cost(
          PhoenixKitCatalogue.Schemas.ItemSupplierInfo.t(),
          Decimal.t(),
          keyword()
        ) ::
          {:ok, PhoenixKitCatalogue.Schemas.ItemSupplierInfo.t()}
          | {:error, :not_current | Ecto.Changeset.t()}
  def revise_unit_cost(info, new_cost, opts \\ []),
    do: ItemSupplierInfos.revise_unit_cost(info, new_cost, opts)

  # ── CRM helpers ────────────────────────────────────────────────────────────
  # All CRM calls are guarded behind function_exported? so the catalogue
  # module compiles and runs without the CRM module present. CRM is an
  # optional soft dependency — its absence is not an error.

  defp try_resolve_crm(uuid) do
    if crm_available?() do
      case apply(PhoenixKitCRM.PartyRoles, :get_supplier, [uuid]) do
        nil ->
          :error

        party ->
          {:ok,
           %{
             uuid: uuid,
             name: party.name,
             email: Map.get(party, :email),
             phone: Map.get(party, :phone),
             website: Map.get(party, :website),
             source: :crm
           }}
      end
    else
      :error
    end
  end

  # `PartyRoles.get_supplier/1` federates both roleable types behind one
  # call but doesn't say which it hydrated (see `resolve/1` doc), so
  # listing goes through the per-type role queries instead — that's also
  # what lets each entry carry the specific `:crm_company` / `:crm_contact`
  # tag that `ItemFormLive` persists onto `item_supplier_info.supplier_source`.
  defp list_crm_suppliers do
    if crm_available?() do
      list_crm_companies() ++ list_crm_contacts()
    else
      []
    end
  end

  defp list_crm_companies do
    if function_exported?(PhoenixKitCRM.PartyRoles, :list_companies_with_role, 2) do
      apply(PhoenixKitCRM.PartyRoles, :list_companies_with_role, ["supplier", []])
      |> Enum.map(fn c ->
        %{
          uuid: c.uuid,
          name: blank_to_unnamed(c.name),
          email: c.email,
          phone: c.phone,
          website: c.website,
          source: :crm_company
        }
      end)
    else
      []
    end
  end

  defp list_crm_contacts do
    if function_exported?(PhoenixKitCRM.PartyRoles, :list_contacts_with_role, 2) do
      apply(PhoenixKitCRM.PartyRoles, :list_contacts_with_role, ["supplier", []])
      |> Enum.map(fn c ->
        %{
          uuid: c.uuid,
          name: if(c.name in [nil, ""], do: blank_to_unnamed(c.email), else: c.name),
          email: c.email,
          phone: c.phone,
          # Contacts have no website field on the CRM side (mirrors
          # `PartyRoles`' own hydration for contacts).
          website: nil,
          source: :crm_contact
        }
      end)
    else
      []
    end
  end

  defp blank_to_unnamed(nil), do: "Unnamed"
  defp blank_to_unnamed(""), do: "Unnamed"
  defp blank_to_unnamed(value), do: value

  defp crm_available? do
    Code.ensure_loaded?(PhoenixKitCRM.PartyRoles) and
      function_exported?(PhoenixKitCRM.PartyRoles, :get_supplier, 1)
  end
end
