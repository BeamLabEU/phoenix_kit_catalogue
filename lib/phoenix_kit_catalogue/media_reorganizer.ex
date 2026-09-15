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
  stale `catalogue-attachment-pending-*` upload folders, orphaned legacy
  folders whose record is gone or deleted (reported, never moved/trashed —
  see "Orphaned legacy folders" below), and the shared PDF library folder
  (reported, not moved — see moduledoc "PDF library" below).
  """

  import Ecto.Query, warn: false

  alias PhoenixKit.Modules.Storage.{File, Folder, FolderLink}
  alias PhoenixKitCatalogue.Attachments
  alias PhoenixKitCatalogue.Schemas.{Catalogue, Category, Item, Pdf}

  @pending_prefix "catalogue-attachment-pending-"
  @default_pending_days 7

  @doc """
  Builds the catalogue's reorganizer plan: one `:move` action per catalogue,
  category and item whose current folder does not already match its hooks,
  plus `:trash`/`:report` actions for stale pending folders, a `:report`
  (`kind: :orphan`) per legacy folder whose record is gone or deleted, and a
  `:report` for PDFs stranded at the storage root while a library folder is
  configured.

  `opts[:pending_days]` (default #{@default_pending_days}) — how old an
  empty pending folder must be before it is reported as `:trash` instead of
  left alone.
  """
  @spec plan(String.t() | nil, keyword()) :: [map()]
  def plan(actor_uuid, opts \\ []) do
    pending_days = Keyword.get(opts, :pending_days, @default_pending_days)

    tagged_records =
      tag(live_catalogues(), :catalogue) ++
        tag(live_categories(), :category) ++
        tag(live_items(), :item)

    # Desired parent/name (the host hooks, possibly a DB lookup or a
    # lazily-created folder on the host side) is resolved exactly once per
    # record here and threaded into both passes below — `orphan_actions/1`
    # reuses `desired`'s `parent_uuid`s instead of re-running the hook.
    desired = resolve_desired(tagged_records, actor_uuid)

    resource_actions(desired) ++
      orphan_actions(desired) ++
      pending_folder_actions(pending_days) ++
      pdf_report_actions(actor_uuid)
  end

  # ── Catalogues / categories / items ─────────────────────────────

  defp tag(records, kind), do: Enum.map(records, &{&1, kind})

  defp resolve_desired(tagged_records, actor_uuid) do
    Enum.map(tagged_records, fn {record, kind} ->
      %{
        record: record,
        kind: kind,
        parent_uuid: Attachments.parent_folder_uuid(record, actor_uuid),
        name: Attachments.folder_name(record, actor_uuid),
        legacy_name: Attachments.legacy_folder_name(record),
        pointer: pointer_uuid(record)
      }
    end)
  end

  # Every folder lookup for the whole batch runs as three preloaded queries
  # (pointer uuids, legacy names at root, legacy names under a parent)
  # instead of one-to-three individual round trips per record — the
  # difference between ~3 queries and 2,500+ on a full catalogue.
  defp resource_actions(desired) do
    by_pointer = preload_by_uuid(Enum.map(desired, & &1.pointer))
    by_root_name = preload_by_root_name(Enum.map(desired, & &1.legacy_name))
    by_parent_name = preload_by_parent_name(desired)

    desired
    |> Enum.map(&resource_action(&1, by_pointer, by_root_name, by_parent_name))
    |> Enum.reject(&is_nil/1)
  end

  defp resource_action(desired, by_pointer, by_root_name, by_parent_name) do
    %{record: record, kind: kind, parent_uuid: parent_uuid, name: name} = desired

    case current_folder(desired, by_pointer, by_root_name, by_parent_name) do
      nil ->
        nil

      %Folder{} = folder ->
        after_move = after_move_fun(record, desired.pointer, folder)

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

  defp pointer_uuid(%{data: data}) when is_map(data), do: Map.get(data, "files_folder_uuid")
  defp pointer_uuid(_), do: nil

  # One query for every distinct pointer uuid in the batch.
  defp preload_by_uuid(uuids) do
    case Enum.reject(Enum.uniq(uuids), &is_nil/1) do
      [] -> %{}
      uuids -> Folder |> where([f], f.uuid in ^uuids) |> repo().all() |> Map.new(&{&1.uuid, &1})
    end
  end

  # One query for every distinct legacy name in the batch, at root.
  defp preload_by_root_name(names) do
    case Enum.reject(Enum.uniq(names), &is_nil/1) do
      [] ->
        %{}

      names ->
        Folder
        |> where([f], f.name in ^names and is_nil(f.parent_uuid))
        |> repo().all()
        |> Map.new(&{&1.name, &1})
    end
  end

  # One query for every distinct legacy name under every distinct resolved
  # parent in the batch (a name × parent cross-match, filtered client-side
  # to exact pairs when read) — still one round trip for the whole batch.
  defp preload_by_parent_name(desired) do
    names = desired |> Enum.map(& &1.legacy_name) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    parents = desired |> Enum.map(& &1.parent_uuid) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if names == [] or parents == [] do
      %{}
    else
      Folder
      |> where([f], f.name in ^names and f.parent_uuid in ^parents)
      |> repo().all()
      |> Map.new(&{{&1.name, &1.parent_uuid}, &1})
    end
  end

  # Pointer, if it still resolves to a live folder; else the legacy
  # deterministic name at root; else the legacy name under the resolved
  # parent. `nil` when none of those exist — nothing to move.
  defp current_folder(desired, by_pointer, by_root_name, by_parent_name) do
    %{legacy_name: legacy_name, parent_uuid: parent_uuid, pointer: pointer} = desired

    live_or_nil(pointer && Map.get(by_pointer, pointer)) ||
      (legacy_name && live_or_nil(Map.get(by_root_name, legacy_name))) ||
      (legacy_name && parent_uuid &&
         live_or_nil(Map.get(by_parent_name, {legacy_name, parent_uuid})))
  end

  defp live_or_nil(%Folder{trashed_at: nil} = folder), do: folder
  defp live_or_nil(_), do: nil

  # `nil` when the pointer already matches the current (pre-move) folder —
  # nothing to back-fill. Otherwise a fun the engine runs after the move,
  # inside the same transaction, to write/repair the pointer.
  defp after_move_fun(record, pointer, %Folder{uuid: folder_uuid}) do
    if pointer == folder_uuid do
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

  # ── Orphaned legacy folders ──────────────────────────────────────

  # A legacy-named folder (`catalogue-item-<uuid>`, `catalogue-category-<uuid>`,
  # `catalogue-<uuid>`) at the media root or under a parent this batch's hooks
  # resolved to, whose uuid no longer names a live record (missing, or the
  # record exists but was soft-deleted — same status rule `live_*/0` above
  # uses to drop it from the plan) is reported so a host can collect it. Never
  # `:move`d or `:trash`ed here — this module owns no "orphans" container; a
  # legacy folder that IS a live record's current folder is left to
  # `resource_action/4` above. Reuses `desired`'s `parent_uuid`s (already
  # resolved once per record in `plan/2`) rather than calling the host hook
  # again — that hook can be a DB lookup or create a folder on the host side.
  defp orphan_actions(desired) do
    resolved_parents =
      desired
      |> Enum.map(& &1.parent_uuid)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case legacy_candidate_folders(resolved_parents) do
      [] ->
        []

      candidates ->
        records_by_key = load_candidate_records(candidates)

        candidates
        |> Enum.map(&orphan_action(&1, records_by_key))
        |> Enum.reject(&is_nil/1)
    end
  end

  # One query for every legacy-named folder at root or under a resolved
  # parent — not a query per folder.
  defp legacy_candidate_folders(parent_uuids) do
    Folder
    |> where([f], is_nil(f.trashed_at))
    |> where([f], is_nil(f.parent_uuid) or f.parent_uuid in ^parent_uuids)
    |> repo().all()
    |> Enum.map(&{&1, legacy_kind(&1.name)})
    |> Enum.filter(fn {_folder, kind} -> kind end)
  end

  @legacy_kinds [
    {"catalogue-item-", :item},
    {"catalogue-category-", :category},
    {"catalogue-", :catalogue}
  ]

  defp legacy_kind(name) do
    if String.starts_with?(name, @pending_prefix) do
      nil
    else
      Enum.find_value(@legacy_kinds, &legacy_kind_match(name, &1))
    end
  end

  defp legacy_kind_match(name, {prefix, kind}) do
    with true <- String.starts_with?(name, prefix),
         uuid <- String.replace_prefix(name, prefix, ""),
         {:ok, _} <- Ecto.UUID.cast(uuid) do
      {kind, uuid}
    else
      _ -> nil
    end
  end

  # One query per record kind present among the candidates — not per folder.
  defp load_candidate_records(candidates) do
    by_kind =
      Enum.group_by(
        candidates,
        fn {_folder, {kind, _uuid}} -> kind end,
        fn {_folder, {_kind, uuid}} -> uuid end
      )

    %{}
    |> Map.merge(load_records(Item, :item, Map.get(by_kind, :item, [])))
    |> Map.merge(load_records(Category, :category, Map.get(by_kind, :category, [])))
    |> Map.merge(load_records(Catalogue, :catalogue, Map.get(by_kind, :catalogue, [])))
  end

  defp load_records(_schema, _kind, []), do: %{}

  defp load_records(schema, kind, uuids) do
    schema
    |> where([r], r.uuid in ^uuids)
    |> repo().all()
    |> Map.new(&{{kind, &1.uuid}, &1})
  end

  defp orphan_action({folder, {kind, uuid}}, records_by_key) do
    case Map.get(records_by_key, {kind, uuid}) do
      %{status: status} when status != "deleted" ->
        nil

      record ->
        counts = counts(folder.uuid)

        %{
          source: "catalogue",
          kind: :orphan,
          op: :report,
          label: folder.name,
          folder: folder,
          counts: counts,
          reason: orphan_reason(record, counts)
        }
    end
  end

  defp orphan_reason(nil, {files, _links}), do: "record missing, #{files} file(s)"

  defp orphan_reason(%{status: status}, {files, _links}),
    do: "record status #{status}, #{files} file(s)"

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

  # Counts ALL rows regardless of status (including trashed files) — the
  # core engine re-measures the same way at apply time (any row with this
  # `folder_uuid`) and aborts the action on a mismatch, so a plan-time
  # count that excluded trashed files would fail every folder holding one.
  defp counts(folder_uuid) do
    files =
      File
      |> where([f], f.folder_uuid == ^folder_uuid)
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
