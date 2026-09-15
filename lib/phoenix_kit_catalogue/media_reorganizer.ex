defmodule PhoenixKitCatalogue.MediaReorganizer do
  @moduledoc """
  Catalogue's media-reorganizer plan source.

  Not compiled against a core `PhoenixKit.Modules.Storage.Reorganizer.Source`
  behaviour — today's hex core (2.23.x) does not ship the engine yet. This
  module declares no `@behaviour` and returns plain maps; see
  `PhoenixKitCatalogue.media_reorganizer/0` for the registration comment.
  Once core ships the engine, `plan/2`'s contract (`plan(actor_uuid, opts)
  :: [map()]`) already matches `Source.plan/2` — the only follow-up is
  adding `@behaviour`/`@impl`.

  `plan/2` derives the desired parent/name from the exact hooks
  (`Attachments.parent_folder_uuid/2`, `Attachments.folder_name/2`) that a
  fresh upload uses, so a plan describes exactly what the module would do
  today. Once every folder already sits where its plan says, the engine's
  `Action.noop?/1` filters the action out — a second run plans nothing.

  Covers catalogues, categories and items (their own attachment folders),
  stale `catalogue-attachment-pending-*` upload folders, and the shared PDF
  library folder (reported, not moved — see moduledoc "PDF library" below).
  """

  import Ecto.Query, warn: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{File, Folder, FolderLink}
  alias PhoenixKitCatalogue.Attachments
  alias PhoenixKitCatalogue.Schemas.{Catalogue, Category, Item, Pdf}

  @pending_prefix "catalogue-attachment-pending-"
  @default_pending_days 7

  @doc """
  Builds the catalogue's reorganizer plan: one `:move` action per catalogue,
  category and item whose current folder does not already match its hooks,
  plus `:trash`/`:report` actions for stale pending folders and a `:report`
  for PDFs stranded at the storage root while a library folder is
  configured.

  `opts[:pending_days]` (default #{@default_pending_days}) — how old an
  empty pending folder must be before it is reported as `:trash` instead of
  left alone.
  """
  @spec plan(String.t() | nil, keyword()) :: [map()]
  def plan(actor_uuid, opts \\ []) do
    pending_days = Keyword.get(opts, :pending_days, @default_pending_days)

    resource_actions(live_catalogues(), :catalogue, actor_uuid) ++
      resource_actions(live_categories(), :category, actor_uuid) ++
      resource_actions(live_items(), :item, actor_uuid) ++
      pending_folder_actions(pending_days) ++
      pdf_report_actions(actor_uuid)
  end

  # ── Catalogues / categories / items ─────────────────────────────

  defp resource_actions(records, kind, actor_uuid) do
    records
    |> Enum.map(&resource_action(&1, kind, actor_uuid))
    |> Enum.reject(&is_nil/1)
  end

  defp resource_action(record, kind, actor_uuid) do
    case current_folder(record, actor_uuid) do
      nil ->
        nil

      %Folder{} = folder ->
        parent_uuid = Attachments.parent_folder_uuid(record, actor_uuid)
        name = Attachments.folder_name(record, actor_uuid)
        after_move = after_move_fun(record, folder)

        if noop_move?(folder, parent_uuid, name) and is_nil(after_move) do
          nil
        else
          %{
            source: "catalogue",
            kind: kind,
            label: record.name,
            op: :move,
            folder: folder,
            parent_uuid: parent_uuid,
            name: name,
            counts: counts(folder.uuid),
            on_conflict: :suffix,
            after_move: after_move
          }
        end
    end
  end

  # A `:move` whose folder already sits at `parent_uuid` under `name` (or an
  # accepted `"name (N)"` suffix variant) is a no-op — filtered here since
  # this Source has no core `Action.noop?/1` to lean on. A pointer
  # back-fill still needs the action even when the folder itself would not
  # move (`after_move_fun/2` is checked by the caller).
  defp noop_move?(%Folder{parent_uuid: parent_uuid, name: name}, parent_uuid, name), do: true

  defp noop_move?(%Folder{parent_uuid: parent_uuid, name: folder_name}, parent_uuid, name) do
    suffixed_variant?(folder_name, name)
  end

  defp noop_move?(_folder, _parent_uuid, _name), do: false

  defp suffixed_variant?(folder_name, name) do
    Regex.match?(~r/^#{Regex.escape(name)} \(\d+\)$/, folder_name)
  end

  # Pointer, if it still resolves to a live folder; else the legacy
  # deterministic name at root; else the legacy name under the resolved
  # parent. `nil` when none of those exist — nothing to move.
  defp current_folder(record, actor_uuid) do
    live_folder(pointer_uuid(record)) || legacy_folder(record, actor_uuid)
  end

  defp pointer_uuid(%{data: data}) when is_map(data), do: Map.get(data, "files_folder_uuid")
  defp pointer_uuid(_), do: nil

  defp live_folder(nil), do: nil

  defp live_folder(uuid) do
    case Storage.get_folder(uuid) do
      %Folder{trashed_at: nil} = folder -> folder
      _ -> nil
    end
  end

  defp legacy_folder(record, actor_uuid) do
    case Attachments.legacy_folder_name(record) do
      nil ->
        nil

      name ->
        live_folder_by_name(name, nil) || legacy_folder_under_parent(name, record, actor_uuid)
    end
  end

  defp legacy_folder_under_parent(name, record, actor_uuid) do
    case Attachments.parent_folder_uuid(record, actor_uuid) do
      nil -> nil
      parent -> live_folder_by_name(name, parent)
    end
  end

  defp live_folder_by_name(name, parent_uuid) do
    case Attachments.find_folder_by_name(name, parent_uuid) do
      %Folder{trashed_at: nil} = folder -> folder
      _ -> nil
    end
  end

  # `nil` when the pointer already matches the current (pre-move) folder —
  # nothing to back-fill. Otherwise a fun the engine runs after the move,
  # inside the same transaction, to write/repair the pointer.
  defp after_move_fun(record, %Folder{uuid: folder_uuid}) do
    if pointer_uuid(record) == folder_uuid do
      nil
    else
      fn -> write_pointer(record, folder_uuid) end
    end
  end

  defp write_pointer(%Item{} = item, folder_uuid) do
    write_data_pointer(&PhoenixKitCatalogue.Catalogue.update_item/3, item, folder_uuid)
  end

  defp write_pointer(%Category{} = category, folder_uuid) do
    write_data_pointer(&PhoenixKitCatalogue.Catalogue.update_category/3, category, folder_uuid)
  end

  defp write_pointer(%Catalogue{} = catalogue, folder_uuid) do
    write_data_pointer(&PhoenixKitCatalogue.Catalogue.update_catalogue/3, catalogue, folder_uuid)
  end

  defp write_data_pointer(update_fun, record, folder_uuid) do
    data = %{"files_folder_uuid" => folder_uuid}

    case update_fun.(record, %{data: data}, data_owned_keys: Map.keys(data)) do
      {:ok, _updated} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Pending upload folders ──────────────────────────────────────

  defp pending_folder_actions(pending_days) do
    cutoff = DateTime.add(DateTime.utc_now(), -pending_days * 86_400, :second)

    Folder
    |> where([f], is_nil(f.trashed_at))
    |> where([f], like(f.name, ^"#{@pending_prefix}%"))
    |> repo().all()
    |> Enum.map(&pending_folder_action(&1, cutoff))
    |> Enum.reject(&is_nil/1)
  end

  defp pending_folder_action(folder, cutoff) do
    case counts(folder.uuid) do
      {0, 0} ->
        if DateTime.compare(folder.inserted_at, cutoff) == :lt do
          %{
            source: "catalogue",
            kind: :pending,
            label: folder.name,
            op: :trash,
            folder: folder,
            counts: {0, 0},
            reason: "empty pending upload folder older than the retention window"
          }
        end

      {files, links} ->
        names = pending_file_names(folder.uuid)

        %{
          source: "catalogue",
          kind: :pending,
          label: folder.name,
          op: :report,
          folder: folder,
          counts: {files, links},
          reason: "pending folder still has files: #{Enum.join(names, ", ")}"
        }
    end
  end

  defp pending_file_names(folder_uuid) do
    folder_uuid
    |> Attachments.folder_files_query()
    |> repo().all()
    |> Enum.map(& &1.original_file_name)
  end

  # ── PDF library ──────────────────────────────────────────────────

  # PDFs are files, not folders — out of scope for a `:move` action. Live
  # PDFs still sitting at the storage root while the host has configured a
  # library folder (`:pdf` hook) get a single `:report` so a human can run
  # the legacy-adoption pass `PdfLibrary` itself defers to (see its
  # `attach_to_pdf_library_folder/2` moduledoc comment).
  defp pdf_report_actions(actor_uuid) do
    case Attachments.parent_folder_uuid(:pdf, actor_uuid) do
      folder_uuid when is_binary(folder_uuid) ->
        case root_pdf_count() do
          0 ->
            []

          count ->
            [
              %{
                source: "catalogue",
                kind: :pdf,
                label: "PDF library",
                op: :report,
                counts: {count, 0},
                reason: "#{count} PDF(s) at the storage root; library folder #{folder_uuid}"
              }
            ]
        end

      _ ->
        []
    end
  end

  defp root_pdf_count do
    Pdf
    |> join(:inner, [p], f in File, on: f.uuid == p.file_uuid)
    |> where([p, f], p.status == "active" and f.status != "trashed" and is_nil(f.folder_uuid))
    |> repo().aggregate(:count)
  end

  # ── Shared helpers ───────────────────────────────────────────────

  defp counts(folder_uuid) do
    files =
      File
      |> where([f], f.folder_uuid == ^folder_uuid and f.status != "trashed")
      |> repo().aggregate(:count)

    links =
      FolderLink
      |> where([l], l.folder_uuid == ^folder_uuid)
      |> repo().aggregate(:count)

    {files, links}
  end

  defp live_catalogues do
    Catalogue |> where([c], c.status != "deleted") |> repo().all()
  end

  defp live_categories do
    Category
    |> where([c], c.status != "deleted")
    |> order_by([c], asc_nulls_first: c.parent_uuid)
    |> repo().all()
  end

  defp live_items do
    Item |> where([i], i.status != "deleted") |> repo().all()
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
