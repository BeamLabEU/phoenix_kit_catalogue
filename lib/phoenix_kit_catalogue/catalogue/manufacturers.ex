defmodule PhoenixKitCatalogue.Catalogue.Manufacturers do
  @moduledoc """
  Manufacturers — company directory used as the source of items.

  Hard-deletes only (manufacturers are reference data, not user content).
  Status field is `"active"` / `"inactive"`; inactive manufacturers
  remain in the DB but are filtered from item dropdowns.

  Public surface is re-exported from `PhoenixKitCatalogue.Catalogue` via
  `defdelegate`, so callers can keep using the canonical context module.
  """

  import Ecto.Query, warn: false

  alias PhoenixKitCatalogue.Catalogue.{ActivityLog, PubSub}
  alias PhoenixKitCatalogue.Schemas.Manufacturer

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc """
  Lists all manufacturers, ordered by name.

  ## Options

    * `:status` — filter by status (e.g. `"active"`, `"inactive"`).
      When nil (default), returns all manufacturers.
  """
  @spec list_manufacturers(keyword()) :: [Manufacturer.t()]
  def list_manufacturers(opts \\ []) do
    query = from(m in Manufacturer, order_by: [asc: :name])

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status -> where(query, [m], m.status == ^status)
      end

    repo().all(query)
  end

  @doc "Fetches a manufacturer by UUID. Returns `nil` if not found."
  @spec get_manufacturer(Ecto.UUID.t()) :: Manufacturer.t() | nil
  def get_manufacturer(uuid), do: repo().get(Manufacturer, uuid)

  @doc "Fetches a manufacturer by UUID. Raises `Ecto.NoResultsError` if not found."
  @spec get_manufacturer!(Ecto.UUID.t()) :: Manufacturer.t()
  def get_manufacturer!(uuid), do: repo().get!(Manufacturer, uuid)

  @doc """
  Creates a manufacturer.

  ## Required attributes

    * `:name` — manufacturer name (1-255 chars)

  ## Optional attributes

    * `:description`, `:website`, `:contact_info`, `:logo_url`, `:notes`
    * `:status` — `"active"` (default) or `"inactive"`
    * `:data` — flexible JSON map
  """
  @spec create_manufacturer(map(), keyword()) ::
          {:ok, Manufacturer.t()} | {:error, Ecto.Changeset.t(Manufacturer.t())}
  def create_manufacturer(attrs, opts \\ []) do
    result =
      ActivityLog.with_log(
        fn -> %Manufacturer{} |> Manufacturer.changeset(attrs) |> repo().insert() end,
        fn manufacturer ->
          %{
            action: "manufacturer.created",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "manufacturer",
            resource_uuid: manufacturer.uuid,
            metadata: %{"name" => manufacturer.name}
          }
        end
      )

    with {:ok, manufacturer} <- result do
      PubSub.broadcast(:manufacturer, manufacturer.uuid)
      {:ok, manufacturer}
    end
  end

  @doc "Updates a manufacturer with the given attributes."
  @spec update_manufacturer(Manufacturer.t(), map(), keyword()) ::
          {:ok, Manufacturer.t()} | {:error, Ecto.Changeset.t(Manufacturer.t())}
  def update_manufacturer(%Manufacturer{} = manufacturer, attrs, opts \\ []) do
    result =
      ActivityLog.with_log(
        fn -> manufacturer |> Manufacturer.changeset(attrs) |> repo().update() end,
        fn updated ->
          %{
            action: "manufacturer.updated",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "manufacturer",
            resource_uuid: updated.uuid,
            metadata: %{"name" => updated.name}
          }
        end
      )

    with {:ok, updated} <- result do
      PubSub.broadcast(:manufacturer, updated.uuid)
      {:ok, updated}
    end
  end

  @doc "Hard-deletes a manufacturer from the database."
  @spec delete_manufacturer(Manufacturer.t(), keyword()) ::
          {:ok, Manufacturer.t()} | {:error, Ecto.Changeset.t(Manufacturer.t())}
  def delete_manufacturer(%Manufacturer{} = manufacturer, opts \\ []) do
    result =
      ActivityLog.with_log(
        fn -> repo().delete(manufacturer) end,
        fn _ ->
          %{
            action: "manufacturer.deleted",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "manufacturer",
            resource_uuid: manufacturer.uuid,
            metadata: %{"name" => manufacturer.name}
          }
        end
      )

    with {:ok, deleted} <- result do
      PubSub.broadcast(:manufacturer, manufacturer.uuid)
      {:ok, deleted}
    end
  end

  @doc "Returns a changeset for tracking manufacturer changes."
  @spec change_manufacturer(Manufacturer.t(), map()) :: Ecto.Changeset.t(Manufacturer.t())
  def change_manufacturer(%Manufacturer{} = manufacturer, attrs \\ %{}) do
    Manufacturer.changeset(manufacturer, attrs)
  end

  # ── Cross-module resolution ────────────────────────────────────────────────
  # Mirrors `PhoenixKitCatalogue.Catalogue.Suppliers`' resolver pair, with one
  # important difference stated up front: items reference manufacturers through
  # the HARD FK `phoenix_kit_cat_items.manufacturer_uuid`, so a CRM party uuid
  # can never be stored there. These functions federate the manufacturer
  # DIRECTORY (and any picker built on it); they do not make item references
  # federated. See `PhoenixKitCatalogue.Catalogue.CrmLink`.

  @doc """
  Resolves a manufacturer UUID to a unified map regardless of source.

  Returns `{:ok, map}` with keys `:uuid`, `:name`, `:email`, `:phone`,
  `:website`, `:source` (`:crm | :local`), or `:error` when the uuid is
  unknown to both sources. CRM is consulted first and only when the CRM
  module is loaded.
  """
  @spec resolve(Ecto.UUID.t()) :: {:ok, map()} | :error
  def resolve(uuid) when is_binary(uuid) do
    with :error <- try_resolve_crm(uuid) do
      case repo().get(Manufacturer, uuid) do
        nil ->
          :error

        %Manufacturer{} = m ->
          {:ok,
           %{
             uuid: m.uuid,
             name: m.name,
             email: nil,
             phone: nil,
             website: m.website,
             source: :local
           }}
      end
    end
  end

  @doc """
  Lists manufacturers from all available sources as normalized maps.

  CRM parties holding an active `manufacturer` role come first, then local
  rows ordered by name. Local rows already linked to a CRM party are omitted:
  the party side of the same company is in the list already, and emitting both
  would show one company twice.
  """
  @spec list_all(keyword()) :: [map()]
  def list_all(opts \\ []) do
    local =
      opts
      |> list_manufacturers()
      |> Enum.reject(& &1.crm_company_uuid)
      |> Enum.map(fn m ->
        %{
          uuid: m.uuid,
          name: m.name,
          email: nil,
          phone: nil,
          website: m.website,
          source: :local
        }
      end)

    list_crm_manufacturers() ++ local
  end

  defp try_resolve_crm(uuid) do
    if crm_available?() do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      case apply(PhoenixKitCRM.PartyRoles, :get_manufacturer, [uuid]) do
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

  defp list_crm_manufacturers do
    if crm_available?() and
         function_exported?(PhoenixKitCRM.PartyRoles, :list_manufacturers, 1) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(PhoenixKitCRM.PartyRoles, :list_manufacturers, [[]])
    else
      []
    end
  end

  defp crm_available? do
    Code.ensure_loaded?(PhoenixKitCRM.PartyRoles) and
      function_exported?(PhoenixKitCRM.PartyRoles, :get_manufacturer, 1)
  end
end
