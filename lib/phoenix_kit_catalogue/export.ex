defmodule PhoenixKitCatalogue.Export do
  @moduledoc """
  Export context for the Catalogue module.

  Drives the Export tab: registry of sources, item selection, and
  in-memory file generation. Nothing is persisted to disk.

  ## Usage

      sources = Export.sources()
      items   = Export.list_export_items(catalogue_uuid)
      # or with category scope:
      items   = Export.list_export_items(catalogue_uuid, category_uuid)

      {filename, content, mime} = Export.build(%{
        source: :pro100,
        format: :furniture,
        catalogue_uuid: catalogue_uuid,
        category_uuid: nil
      })
  """

  import Ecto.Query, warn: false

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.Tree
  alias PhoenixKitCatalogue.Schemas.{Category, Item}

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ---------------------------------------------------------------------------
  # Source registry
  # ---------------------------------------------------------------------------

  @sources [PhoenixKitCatalogue.Export.Pro100]

  @doc """
  Returns the list of registered export source modules.
  Each element implements `PhoenixKitCatalogue.Export.Source`.
  """
  @spec sources() :: [module()]
  def sources, do: @sources

  @doc """
  Finds a source module by its atom key, or `nil` if not found.
  """
  @spec source_by_key(atom() | String.t()) :: module() | nil
  def source_by_key(key) when is_atom(key) do
    Enum.find(@sources, fn mod -> mod.key() == key end)
  end

  def source_by_key(key) when is_binary(key) do
    atom_key = String.to_existing_atom(key)
    source_by_key(atom_key)
  rescue
    ArgumentError -> nil
  end

  # ---------------------------------------------------------------------------
  # Item selection
  # ---------------------------------------------------------------------------

  @doc """
  Lists non-deleted items for export.

  - No `category_uuid` (or `nil`) → returns all active items in the catalogue.
  - `category_uuid` given → returns items in that category and all descendant
    categories (subtree expansion via `Catalogue.Tree`).

  Items are ordered by category position, then item position, then name.
  The `:category` association is preloaded on every item.
  """
  @spec list_export_items(Ecto.UUID.t(), Ecto.UUID.t() | nil) :: [Item.t()]
  def list_export_items(catalogue_uuid, category_uuid \\ nil)

  def list_export_items(catalogue_uuid, nil) do
    Catalogue.list_items_for_catalogue(catalogue_uuid)
  end

  def list_export_items(catalogue_uuid, category_uuid) when is_binary(category_uuid) do
    subtree = Tree.subtree_uuids(category_uuid)

    from(i in Item,
      left_join: c in Category,
      on: i.category_uuid == c.uuid,
      where:
        i.catalogue_uuid == ^catalogue_uuid and
          i.category_uuid in ^subtree and
          i.status != "deleted",
      order_by: [asc_nulls_last: c.position, asc: i.position, asc: i.name],
      preload: [:catalogue, category: :catalogue, manufacturer: []]
    )
    |> repo().all()
  end

  # ---------------------------------------------------------------------------
  # Build
  # ---------------------------------------------------------------------------

  @doc """
  Builds the export file in memory.

  `params` is a map with keys:
  - `:source` — atom or string source key (e.g. `:pro100` or `"pro100"`)
  - `:format` — atom or string format key (e.g. `:furniture` or `"furniture"`)
  - `:catalogue_uuid` — UUID of the catalogue to export
  - `:category_uuid` — optional UUID; `nil` exports the whole catalogue

  Returns `{filename, iodata, mime_type}`.

  Raises `ArgumentError` if the source or format is not recognised.
  """
  @spec build(map()) :: {String.t(), iodata(), String.t()}
  def build(%{source: source_key, format: format_key} = params) do
    catalogue_uuid = Map.fetch!(params, :catalogue_uuid)
    category_uuid = Map.get(params, :category_uuid)

    source_mod =
      source_by_key(to_atom(source_key)) ||
        raise ArgumentError, "unknown export source: #{inspect(source_key)}"

    format_atom = to_atom(format_key)

    unless Enum.any?(source_mod.formats(), fn {k, _} -> k == format_atom end) do
      raise ArgumentError,
            "unknown format #{inspect(format_key)} for source #{inspect(source_mod.key())}"
    end

    items = list_export_items(catalogue_uuid, category_uuid)
    catalogue = Catalogue.get_catalogue!(catalogue_uuid)

    category =
      if is_binary(category_uuid) and byte_size(category_uuid) > 0 do
        Catalogue.get_category!(category_uuid)
      else
        nil
      end

    ctx = %{
      items: items,
      index: System.os_time(:second),
      catalogue: catalogue,
      category: category
    }

    source_mod.render(format_atom, ctx)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp to_atom(value) when is_atom(value), do: value
  defp to_atom(value) when is_binary(value), do: String.to_existing_atom(value)
end
