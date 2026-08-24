defmodule PhoenixKitCatalogue.Catalogue.Duplication do
  @moduledoc """
  Copies of items and categories — the "Duplicate" bulk action.

  An item copy is the row plus everything the item form edits alongside
  it: multilang `data` (translations, custom fields, featured-image
  pointer), attribute-set attachments, the attribute-group assignment,
  the CURRENT supplier rows, catalogue rules, and its files folder. Files
  are not re-uploaded: the copy gets its own Storage folder with a
  `FolderLink` to each of the source's files, so removing one from the
  copy never touches the original. Supplier rows get a FRESH comment
  thread — a discount promised on the original stays on the original.
  Comments and activity history are not copied.

  A category copy is the category row (same treatment) plus its whole
  subtree: every active child category and every non-trashed item, each
  keeping its own name and position. Only the top-level copy is renamed
  ("Alpha (copy)") and slotted right after its source.

  Everything for one copy runs in one transaction; the bulk functions
  run one transaction per source so a refused row does not undo the
  others, and emit ONE batch event per touched catalogue afterwards.

  Public surface is re-exported from `PhoenixKitCatalogue.Catalogue`.
  """

  import Ecto.Query, warn: false
  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{File, Folder, FolderLink}
  alias PhoenixKitCatalogue.Catalogue.{ActivityLog, PubSub, SupplierComments}

  alias PhoenixKitCatalogue.Schemas.{
    CatalogueRule,
    Category,
    Item,
    ItemAttributeGroup,
    ItemAttributeSet,
    ItemSupplierInfo
  }

  @item_fields [
    :description,
    :sku,
    :base_price,
    :markup_percentage,
    :discount_percentage,
    :default_value,
    :default_unit,
    :unit,
    :status,
    :manufacturer_uuid,
    :manufacturer_source,
    :manufacturer_name_snapshot
  ]

  @supplier_fields [
    :supplier_uuid,
    :supplier_source,
    :supplier_name_snapshot,
    :supplier_sku,
    :unit_cost,
    :currency,
    :lead_time_days,
    :min_order_qty,
    :is_primary,
    :valid_from,
    :position
  ]

  # The folder pointer belongs to exactly one resource; the copy gets its
  # own folder (see `copy_files_folder/3`) or none.
  @data_keys_not_copied ["files_folder_uuid"]

  # Same ceiling as the form's files grid — a folder with thousands of
  # files is stale data, not something to fan a copy out over.
  @files_limit 200

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @type bulk_result :: {:ok, %{created: non_neg_integer(), errors: [{Ecto.UUID.t(), term()}]}}

  @doc """
  Copies one item. Options:

    * `:category_uuid` — put the copy in this category (`nil` = uncategorized)
      instead of the source's; the catalogue follows the category.
    * `:suffix` — append " (copy)" to the name (default `true`).
    * `:keep_position` — keep the source's position number verbatim instead of
      slotting the copy right after the source (default `false`; used for
      subtree copies where the whole sibling set moves together).
    * `:actor_uuid`, `:mode`, `:broadcast` — as elsewhere in the context.
  """
  @spec duplicate_item(Item.t(), keyword()) :: {:ok, Item.t()} | {:error, term()}
  def duplicate_item(%Item{} = source, opts \\ []) do
    case repo().transaction(fn -> copy_item(source, opts) end) do
      {:ok, item} ->
        if Keyword.get(opts, :broadcast, true),
          do: PubSub.broadcast(:item, item.uuid, item.catalogue_uuid)

        {:ok, item}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Copies one category with its subtree. Options as `duplicate_item/2`
  (`:parent_uuid` instead of `:category_uuid`). Returns the new category and
  how many descendant categories and items came along.
  """
  @spec duplicate_category(Category.t(), keyword()) ::
          {:ok,
           %{category: Category.t(), categories: non_neg_integer(), items: non_neg_integer()}}
          | {:error, term()}
  def duplicate_category(%Category{} = source, opts \\ []) do
    case repo().transaction(fn -> copy_category(source, opts) end) do
      {:ok, %{category: category} = result} ->
        if Keyword.get(opts, :broadcast, true) do
          PubSub.broadcast(:category, nil, category.catalogue_uuid)
          PubSub.broadcast(:item, nil, category.catalogue_uuid)
        end

        {:ok, result}

      {:error, _} = error ->
        error
    end
  end

  @doc "Copies several items; one transaction each, one `:item` batch event per catalogue."
  @spec bulk_duplicate_items([Ecto.UUID.t()], keyword()) :: bulk_result()
  def bulk_duplicate_items(uuids, opts \\ []) when is_list(uuids) do
    muted = Keyword.put(opts, :broadcast, false)

    {created, errors, catalogues} =
      uuids
      |> load_in_position_order(Item)
      |> Enum.reduce({0, [], MapSet.new()}, fn
        {uuid, :invalid_uuid}, {n, errors, cats} ->
          {n, [{uuid, :invalid_uuid} | errors], cats}

        {uuid, nil}, {n, errors, cats} ->
          {n, [{uuid, :not_found} | errors], cats}

        {uuid, item}, {n, errors, cats} ->
          case duplicate_item(item, muted) do
            {:ok, copy} -> {n + 1, errors, MapSet.put(cats, copy.catalogue_uuid)}
            {:error, reason} -> {n, [{uuid, reason} | errors], cats}
          end
      end)

    if created > 0 and Keyword.get(opts, :broadcast, true),
      do: Enum.each(catalogues, &PubSub.broadcast(:item, nil, &1))

    {:ok, %{created: created, errors: Enum.reverse(errors)}}
  end

  @doc "Copies several categories (each with its subtree); one batch event per catalogue."
  @spec bulk_duplicate_categories([Ecto.UUID.t()], keyword()) :: bulk_result()
  def bulk_duplicate_categories(uuids, opts \\ []) when is_list(uuids) do
    muted = Keyword.put(opts, :broadcast, false)

    {created, errors, catalogues} =
      uuids
      |> load_in_position_order(Category)
      |> Enum.reduce({0, [], MapSet.new()}, fn
        {uuid, :invalid_uuid}, {n, errors, cats} ->
          {n, [{uuid, :invalid_uuid} | errors], cats}

        {uuid, nil}, {n, errors, cats} ->
          {n, [{uuid, :not_found} | errors], cats}

        {uuid, category}, {n, errors, cats} ->
          case duplicate_category(category, muted) do
            {:ok, %{category: copy}} -> {n + 1, errors, MapSet.put(cats, copy.catalogue_uuid)}
            {:error, reason} -> {n, [{uuid, reason} | errors], cats}
          end
      end)

    if created > 0 and Keyword.get(opts, :broadcast, true) do
      Enum.each(catalogues, fn cat ->
        PubSub.broadcast(:category, nil, cat)
        PubSub.broadcast(:item, nil, cat)
      end)
    end

    {:ok, %{created: created, errors: Enum.reverse(errors)}}
  end

  # Sources are copied lowest position first so several copies inside
  # one sibling list land in the same order as their originals. The
  # uuids are client-captured: a malformed one must surface as an error
  # for that entry, not as a query cast crash for the whole batch.
  defp load_in_position_order(uuids, schema) do
    uuids = Enum.uniq(uuids)
    {valid, invalid} = Enum.split_with(uuids, &match?({:ok, _}, Ecto.UUID.cast(&1)))
    rows = repo().all(from(r in schema, where: r.uuid in ^valid)) |> Map.new(&{&1.uuid, &1})

    sorted =
      valid
      |> Enum.map(&{&1, Map.get(rows, &1)})
      |> Enum.sort_by(fn
        {_, nil} -> {1, 0, ""}
        {_, row} -> {0, row.position, row.name}
      end)

    sorted ++ Enum.map(invalid, &{&1, :invalid_uuid})
  end

  # ── Item ──────────────────────────────────────────────────────────

  # Runs inside the caller's transaction; any failure rolls it back.
  defp copy_item(%Item{} = source, opts) do
    category_uuid = Keyword.get(opts, :category_uuid, source.category_uuid)
    catalogue_uuid = catalogue_for(category_uuid, source.catalogue_uuid)
    keep_position? = Keyword.get(opts, :keep_position, false)

    attrs =
      source
      |> Map.take(@item_fields)
      |> Map.merge(%{
        name: copy_name(source.name, opts),
        catalogue_uuid: catalogue_uuid,
        category_uuid: category_uuid,
        position: source.position,
        data: Map.drop(source.data || %{}, @data_keys_not_copied)
      })

    item = insert!(%Item{} |> Item.changeset(attrs))

    copy_attribute_sets(source, item)
    copy_attribute_group(source, item)
    copy_supplier_rows(source, item)
    copy_rules(source, item)
    item = copy_files_folder(source, item, "catalogue-item-#{item.uuid}", opts)

    unless keep_position?, do: place_item_after(source, item)

    ActivityLog.log(%{
      action: "item.duplicated",
      mode: opts[:mode] || "manual",
      actor_uuid: opts[:actor_uuid],
      resource_type: "item",
      resource_uuid: item.uuid,
      parent_catalogue_uuid: item.catalogue_uuid,
      metadata: %{"name" => item.name, "sku" => item.sku || "", "source_uuid" => source.uuid}
    })

    repo().get!(Item, item.uuid)
  end

  defp catalogue_for(nil, fallback), do: fallback

  defp catalogue_for(category_uuid, fallback) do
    case repo().get(Category, category_uuid) do
      nil -> repo().rollback(:category_not_found)
      %Category{catalogue_uuid: uuid} -> uuid || fallback
    end
  end

  defp copy_name(name, opts) do
    if Keyword.get(opts, :suffix, true),
      do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "%{name} (copy)", name: name),
      else: name
  end

  defp copy_attribute_sets(source, item) do
    from(a in ItemAttributeSet, where: a.item_uuid == ^source.uuid)
    |> repo().all()
    |> Enum.each(fn a ->
      insert!(
        ItemAttributeSet.changeset(%ItemAttributeSet{}, %{
          item_uuid: item.uuid,
          set_uuid: a.set_uuid,
          position: a.position,
          data: a.data
        })
      )
    end)
  end

  defp copy_attribute_group(source, item) do
    case repo().get_by(ItemAttributeGroup, item_uuid: source.uuid) do
      nil ->
        :ok

      g ->
        insert!(
          ItemAttributeGroup.changeset(%ItemAttributeGroup{}, %{
            item_uuid: item.uuid,
            attribute_group_uuid: g.attribute_group_uuid,
            position: g.position
          })
        )
    end
  end

  # Only the CURRENT row per supplier (closed revisions are the source's
  # price history, not the copy's). The stored thread key is dropped and
  # a fresh one stamped, so the two items never share supplier comments.
  defp copy_supplier_rows(source, item) do
    from(i in ItemSupplierInfo, where: i.item_uuid == ^source.uuid and is_nil(i.valid_to))
    |> repo().all()
    |> Enum.each(fn row ->
      attrs =
        row
        |> Map.take(@supplier_fields)
        |> Map.merge(%{
          item_uuid: item.uuid,
          metadata: Map.delete(row.metadata || %{}, SupplierComments.thread_key())
        })

      %ItemSupplierInfo{}
      |> ItemSupplierInfo.changeset(attrs)
      |> SupplierComments.stamp_changeset(UUIDv7.generate())
      |> insert!()
    end)
  end

  defp copy_rules(source, item) do
    from(r in CatalogueRule, where: r.item_uuid == ^source.uuid)
    |> repo().all()
    |> Enum.each(fn r ->
      insert!(
        CatalogueRule.changeset(%CatalogueRule{}, %{
          item_uuid: item.uuid,
          referenced_catalogue_uuid: r.referenced_catalogue_uuid,
          value: r.value,
          unit: r.unit,
          position: r.position
        })
      )
    end)
  end

  # ── Files ─────────────────────────────────────────────────────────

  # The source's folder is the stored pointer or, for resources saved
  # before the pointer existed, the deterministic folder name the form
  # uses. No folder or no files → the copy gets none (the form creates
  # one lazily on first upload). With files → a new folder holding a
  # FolderLink to each, so the copy shows the same files without owning
  # them.
  defp copy_files_folder(source, record, folder_name, opts) do
    files =
      case source_folder_uuid(source) do
        nil -> []
        folder_uuid -> list_files(folder_uuid)
      end

    if files == [] do
      record
    else
      folder = create_folder!(folder_name, opts)
      Enum.each(files, &link_file!(folder, &1))
      put_folder_pointer!(record, folder)
    end
  end

  defp link_file!(folder, file) do
    %FolderLink{}
    |> FolderLink.changeset(%{folder_uuid: folder.uuid, file_uuid: file.uuid})
    |> repo().insert(on_conflict: :nothing)
    |> case do
      {:ok, _} -> :ok
      {:error, changeset} -> repo().rollback({:files_folder, changeset})
    end
  end

  defp put_folder_pointer!(record, folder) do
    data = Map.put(record.data || %{}, "files_folder_uuid", folder.uuid)

    record
    |> Ecto.Changeset.change(data: data)
    |> repo().update()
    |> case do
      {:ok, updated} -> updated
      {:error, changeset} -> repo().rollback(changeset)
    end
  end

  defp source_folder_uuid(%{data: data} = source) do
    case data && data["files_folder_uuid"] do
      uuid when is_binary(uuid) ->
        uuid

      _ ->
        name =
          case source do
            %Item{uuid: uuid} -> "catalogue-item-#{uuid}"
            %Category{uuid: uuid} -> "catalogue-category-#{uuid}"
          end

        from(f in Folder,
          where: f.name == ^name and is_nil(f.parent_uuid),
          select: f.uuid,
          limit: 1
        )
        |> repo().one()
    end
  end

  defp list_files(folder_uuid) do
    linked = from(fl in FolderLink, where: fl.folder_uuid == ^folder_uuid, select: fl.file_uuid)

    from(f in File,
      where:
        (f.folder_uuid == ^folder_uuid or f.uuid in subquery(linked)) and f.status != "trashed",
      order_by: [asc: f.inserted_at],
      limit: @files_limit
    )
    |> repo().all()
  end

  defp create_folder!(name, opts) do
    attrs = %{name: name}
    attrs = if opts[:actor_uuid], do: Map.put(attrs, :user_uuid, opts[:actor_uuid]), else: attrs

    case Storage.create_folder(attrs) do
      {:ok, folder} -> folder
      {:error, reason} -> repo().rollback({:files_folder, reason})
    end
  end

  # ── Category ──────────────────────────────────────────────────────

  defp copy_category(%Category{} = source, opts) do
    parent_uuid = Keyword.get(opts, :parent_uuid, source.parent_uuid)
    keep_position? = Keyword.get(opts, :keep_position, false)

    attrs = %{
      name: copy_name(source.name, opts),
      description: source.description,
      status: source.status,
      position: source.position,
      catalogue_uuid: source.catalogue_uuid,
      parent_uuid: parent_uuid,
      data: Map.drop(source.data || %{}, @data_keys_not_copied)
    }

    category = insert!(%Category{} |> Category.changeset(attrs))
    category = copy_files_folder(source, category, "catalogue-category-#{category.uuid}", opts)

    nested = [
      suffix: false,
      keep_position: true,
      actor_uuid: opts[:actor_uuid],
      mode: opts[:mode] || "manual"
    ]

    items =
      from(i in Item,
        where: i.category_uuid == ^source.uuid and i.status != "deleted",
        order_by: [asc: i.position, asc: i.name]
      )
      |> repo().all()
      |> Enum.map(&copy_item(&1, Keyword.put(nested, :category_uuid, category.uuid)))
      |> length()

    {sub_categories, sub_items} =
      from(c in Category,
        where: c.parent_uuid == ^source.uuid and c.status != "deleted",
        order_by: [asc: c.position, asc: c.name]
      )
      |> repo().all()
      |> Enum.reduce({0, 0}, fn child, {cats, its} ->
        %{categories: c, items: i} =
          copy_category(child, Keyword.put(nested, :parent_uuid, category.uuid))

        {cats + 1 + c, its + i}
      end)

    unless keep_position?, do: place_category_after(source, category)

    ActivityLog.log(%{
      action: "category.duplicated",
      mode: opts[:mode] || "manual",
      actor_uuid: opts[:actor_uuid],
      resource_type: "category",
      resource_uuid: category.uuid,
      parent_catalogue_uuid: category.catalogue_uuid,
      metadata: %{
        "name" => category.name,
        "source_uuid" => source.uuid,
        "categories" => sub_categories,
        "items" => items + sub_items
      }
    })

    %{
      category: repo().get!(Category, category.uuid),
      categories: sub_categories,
      items: items + sub_items
    }
  end

  # ── Placement ─────────────────────────────────────────────────────

  # Renumber the copy's sibling list with the copy right after its
  # source (appended when the source is not a sibling — a copy sent to
  # another category). Positions are written 0..n like the reorder path.
  defp place_item_after(source, item) do
    siblings =
      from(i in Item,
        where:
          i.catalogue_uuid == ^item.catalogue_uuid and i.status != "deleted" and
            i.uuid != ^item.uuid,
        order_by: [asc: i.position, asc: i.name],
        select: i.uuid
      )
      |> scope_category(item.category_uuid)
      |> repo().all()

    renumber(Item, insert_after(siblings, source.uuid, item.uuid))
  end

  defp place_category_after(source, category) do
    siblings =
      from(c in Category,
        where:
          c.catalogue_uuid == ^category.catalogue_uuid and c.status != "deleted" and
            c.uuid != ^category.uuid,
        order_by: [asc: c.position, asc: c.name],
        select: c.uuid
      )
      |> scope_parent(category.parent_uuid)
      |> repo().all()

    renumber(Category, insert_after(siblings, source.uuid, category.uuid))
  end

  defp scope_category(query, nil), do: where(query, [i], is_nil(i.category_uuid))
  defp scope_category(query, uuid), do: where(query, [i], i.category_uuid == ^uuid)
  defp scope_parent(query, nil), do: where(query, [c], is_nil(c.parent_uuid))
  defp scope_parent(query, uuid), do: where(query, [c], c.parent_uuid == ^uuid)

  defp insert_after(list, anchor, new) do
    case Enum.find_index(list, &(&1 == anchor)) do
      nil -> list ++ [new]
      idx -> List.insert_at(list, idx + 1, new)
    end
  end

  defp renumber(schema, ordered_uuids) do
    ordered_uuids
    |> Enum.with_index()
    |> Enum.each(fn {uuid, idx} ->
      repo().update_all(from(r in schema, where: r.uuid == ^uuid), set: [position: idx])
    end)
  end

  defp insert!(changeset) do
    case repo().insert(changeset) do
      {:ok, record} -> record
      {:error, changeset} -> repo().rollback(changeset)
    end
  end
end
