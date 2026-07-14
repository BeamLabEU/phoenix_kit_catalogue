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
  `:website`, `:source` (`:crm_company | :crm_contact | :local`), or
  `:error` when the supplier cannot be found in any source.

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
  `:source`. CRM suppliers are listed first (when available), then local
  suppliers ordered by name.

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
          source = crm_party_source(party)

          {:ok,
           %{
             uuid: uuid,
             name: party.name,
             email: Map.get(party, :email),
             phone: Map.get(party, :phone),
             website: Map.get(party, :website),
             source: source
           }}
      end
    else
      :error
    end
  end

  defp list_crm_suppliers do
    if crm_available?() and function_exported?(PhoenixKitCRM.PartyRoles, :list_suppliers, 0) do
      apply(PhoenixKitCRM.PartyRoles, :list_suppliers, [])
      |> Enum.map(fn party ->
        source = crm_party_source(party)

        %{
          uuid: party.uuid,
          name: party.name,
          email: Map.get(party, :email),
          phone: Map.get(party, :phone),
          website: Map.get(party, :website),
          source: source
        }
      end)
    else
      []
    end
  end

  defp crm_available? do
    Code.ensure_loaded?(PhoenixKitCRM.PartyRoles) and
      function_exported?(PhoenixKitCRM.PartyRoles, :get_supplier, 1)
  end

  defp crm_party_source(party) do
    cond do
      Map.has_key?(party, :company_uuid) -> :crm_contact
      true -> :crm_company
    end
  end
end
