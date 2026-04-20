defmodule PhoenixKitCatalogue.Catalogue.Suppliers do
  @moduledoc """
  Suppliers — delivery companies linked to manufacturers via the
  many-to-many `phoenix_kit_cat_manufacturer_suppliers` table.

  Same lifecycle as manufacturers: hard-delete only, `"active"` /
  `"inactive"` status.

  Public surface is re-exported from `PhoenixKitCatalogue.Catalogue`.
  """

  import Ecto.Query, warn: false

  alias PhoenixKitCatalogue.Catalogue.{ActivityLog, PubSub}
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
end
