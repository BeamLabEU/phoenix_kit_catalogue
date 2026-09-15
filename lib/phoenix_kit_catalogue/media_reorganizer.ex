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
  today. Once every folder already sits where its plan says, the plan
  filters the action out itself (see "Move planning" below) — a second run
  plans nothing.

  A host that has not configured `:attachments_parent_folder` is left
  entirely untouched: no move, no pointer back-fill, and the parent hook is
  never even called for a record without some existing candidate folder
  (pointer or legacy name) — see "Move planning".

  Covers catalogues, categories and items (their own attachment folders),
  stale `catalogue-attachment-pending-*` upload folders, orphaned legacy
  folders whose record is gone or deleted (reported, never moved/trashed —
  see "Orphaned legacy folders" below), and the shared PDF library folder
  (reported, not moved — see moduledoc "PDF library" below).

  ## Move planning

  For each live catalogue/category/item:

  1. A record is a *candidate* when it has a live pointer
     (`data["files_folder_uuid"]`, resolved without calling any hook) or a
     live folder anywhere named after its legacy deterministic name
     (`catalogue-item-<uuid>` etc, also resolved without a hook — one
     batched query for the whole plan). A record with neither is left
     alone: nothing exists to move, and the host's parent hook is never
     called for it.
  2. Only for candidates, the host's own hooks resolve the desired parent
     and name — exactly the functions a fresh upload would call.
  3. The record's *current* folder is: its live pointer if it has one
     (kept as-is, `name: nil` — the owner may have renamed it, this module
     never renames a cached folder); else the legacy-named live folder
     under the resolved parent; else the legacy-named live folder at root
     (this order matches `Attachments.find_resource_folder/2`). A legacy
     name live in **both** places is unresolvable — reported as one
     `kind: :duplicate` action naming both folders, nothing moved.
  4. Two (or more) records whose current folder resolves to the very same
     live folder are likewise unresolvable — one `kind: :duplicate` report
     per shared folder, no move for any of them.
  """

  import Ecto.Query, warn: false

  alias PhoenixKit.Modules.Storage.{File, Folder, FolderLink}
  alias PhoenixKitCatalogue.Attachments
  alias PhoenixKitCatalogue.Schemas.{Catalogue, Category, Item, Pdf}

  @pending_prefix "catalogue-attachment-pending-"
  @default_pending_days 7
  @legacy_prefix "catalogue-"

  @legacy_kinds [
    {"catalogue-item-", :item},
    {"catalogue-category-", :category},
    {"catalogue-", :catalogue}
  ]

  @uuid_regex ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

  @doc """
  Builds the catalogue's reorganizer plan: one `:move` action per catalogue,
  category and item whose current folder does not already match its hooks,
  `:report` (`kind: :duplicate`) actions for folders that cannot be
  unambiguously resolved, `:trash`/`:report` actions for stale pending
  folders, a `:report` (`kind: :orphan`) per legacy folder whose record is
  gone or deleted, and a `:report` for PDFs stranded at the storage root
  while a library folder is configured.

  `opts[:pending_days]` (default #{@default_pending_days}) — how old an
  empty pending folder must be before it is reported as `:trash` instead of
  left alone.
  """
  @spec plan(String.t() | nil, keyword()) :: [map()]
  def plan(actor_uuid, opts \\ []) do
    pending_days = Keyword.get(opts, :pending_days, @default_pending_days)

    {resource_actions, claimed_uuids, resolved_parents} = resource_plan(actor_uuid)

    resource_actions ++
      orphan_actions(resolved_parents) ++
      pending_folder_actions(pending_days, claimed_uuids) ++
      pdf_report_actions(actor_uuid)
  end

  # ── Catalogues / categories / items ─────────────────────────────

  defp resource_plan(actor_uuid) do
    if hook_configured?() do
      tagged_records =
        tag(live_catalogues(), :catalogue) ++
          tag(live_categories(), :category) ++
          tag(live_items(), :item)

      build_resource_plan(tagged_records, actor_uuid)
    else
      {[], MapSet.new([]), []}
    end
  end

  defp hook_configured? do
    match?(
      {mod, fun} when is_atom(mod) and is_atom(fun),
      Application.get_env(:phoenix_kit_catalogue, :attachments_parent_folder)
    )
  end

  defp tag(records, kind), do: Enum.map(records, &{&1, kind})

  # Candidate detection needs no hook call: a live pointer (uuid lookup) or
  # a live folder anywhere named after the record's legacy name. Only
  # candidates go on to have the host's parent/name hooks resolved — a
  # record with nothing pointing at it never triggers a (possibly writing)
  # host hook. See moduledoc "Move planning".
  defp build_resource_plan(tagged_records, actor_uuid) do
    prelim =
      Enum.map(tagged_records, fn {record, kind} ->
        %{
          record: record,
          kind: kind,
          pointer: valid_uuid(pointer_uuid(record)),
          legacy_name: Attachments.legacy_folder_name(record)
        }
      end)

    by_pointer = preload_by_uuid(Enum.map(prelim, & &1.pointer))
    by_name = preload_by_name_anywhere(Enum.map(prelim, & &1.legacy_name))

    candidates =
      Enum.filter(prelim, fn p ->
        (p.pointer && Map.has_key?(by_pointer, p.pointer)) ||
          Map.has_key?(by_name, p.legacy_name)
      end)

    desired =
      Enum.map(candidates, fn p ->
        Map.merge(p, %{
          parent_uuid: Attachments.parent_folder_uuid(p.record, actor_uuid),
          name: Attachments.folder_name(p.record, actor_uuid)
        })
      end)

    entries = Enum.map(desired, &resolve_entry(&1, by_pointer, by_name))

    resolved_parents =
      desired |> Enum.map(& &1.parent_uuid) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    {unique, ambiguous_dup, shared_dup} = classify_entries(entries)

    move_actions = unique |> Enum.map(&build_move_action/1) |> Enum.reject(&is_nil/1)
    dup_actions = Enum.map(ambiguous_dup, &build_ambiguous_duplicate_action/1)
    shared_actions = Enum.map(shared_dup, &build_shared_duplicate_action/1)

    all_actions = move_actions ++ dup_actions ++ shared_actions
    claimed = claimed_folder_uuids(unique, ambiguous_dup, shared_dup)

    {finalize_counts(all_actions), claimed, resolved_parents}
  end

  # Resolves one record's current folder. `:pointer` when its live pointer
  # names a folder (kept as-is downstream — D6: never renamed). Otherwise
  # the legacy name is looked up under the resolved parent, then at root
  # (module's own order — same as `Attachments.find_resource_folder/2`);
  # a live match at both is ambiguous.
  defp resolve_entry(d, by_pointer, by_name) do
    pointer_folder = d.pointer && Map.get(by_pointer, d.pointer)

    if pointer_folder do
      Map.merge(d, %{folder: pointer_folder, via: :pointer, ambiguous: nil})
    else
      matches = Map.get(by_name, d.legacy_name, [])
      under_parent = d.parent_uuid && Enum.find(matches, &(&1.parent_uuid == d.parent_uuid))
      at_root = Enum.find(matches, &is_nil(&1.parent_uuid))

      case {under_parent, at_root} do
        {nil, nil} -> Map.merge(d, %{folder: nil, via: nil, ambiguous: nil})
        {same, same} -> Map.merge(d, %{folder: same, via: :name, ambiguous: nil})
        {f, nil} -> Map.merge(d, %{folder: f, via: :name, ambiguous: nil})
        {nil, f} -> Map.merge(d, %{folder: f, via: :name, ambiguous: nil})
        {f1, f2} -> Map.merge(d, %{folder: nil, via: nil, ambiguous: {f1, f2}})
      end
    end
  end

  # Splits resolved entries into: `unique` (one record ↔ one folder, safe
  # to plan a move for), `ambiguous_dup` (one record, legacy name live at
  # both root and under the resolved parent — X11), `shared_dup` (two or
  # more records resolving to the very same live folder — X5). Every entry
  # in the two dup buckets becomes a `:report kind: :duplicate` instead of
  # a `:move`.
  defp classify_entries(entries) do
    {ambiguous, normal} = Enum.split_with(entries, & &1.ambiguous)
    {with_folder, _without_folder} = Enum.split_with(normal, & &1.folder)

    grouped = Enum.group_by(with_folder, & &1.folder.uuid)

    {shared, unique} =
      Enum.reduce(grouped, {[], []}, fn {_uuid, group}, {shared_acc, unique_acc} ->
        if length(group) > 1 do
          {[group | shared_acc], unique_acc}
        else
          {shared_acc, group ++ unique_acc}
        end
      end)

    {unique, ambiguous, shared}
  end

  defp claimed_folder_uuids(unique, ambiguous_dup, shared_dup) do
    unique_uuids = Enum.map(unique, & &1.folder.uuid)

    ambiguous_uuids =
      Enum.flat_map(ambiguous_dup, fn %{ambiguous: {f1, f2}} -> [f1.uuid, f2.uuid] end)

    shared_uuids = Enum.map(shared_dup, fn [%{folder: f} | _] -> f.uuid end)

    MapSet.new(unique_uuids ++ ambiguous_uuids ++ shared_uuids)
  end

  # A `:move` whose folder already sits at `parent_uuid` under `name` (or
  # an accepted `"name (N)"` suffix variant) and needs no pointer back-fill
  # is a no-op — filtered here since this Source has no core
  # `Action.noop?/1` to lean on. D6: a folder found through the record's
  # pointer keeps `name: nil` (never renamed); only a folder found by
  # legacy name gets the desired name.
  defp build_move_action(%{via: :pointer} = entry), do: move_action(entry, nil)

  defp build_move_action(%{via: :name} = entry), do: move_action(entry, entry.name)

  defp move_action(
         %{record: record, kind: kind, folder: folder, parent_uuid: parent_uuid} = entry,
         name
       ) do
    after_move = after_move_fun(record, entry.pointer, folder)

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
        counts: nil,
        on_conflict: :suffix,
        after_move: after_move
      }
    end
  end

  # `name: nil` (a pointer-found folder, D6) — this module never renames
  # it, so only the parent needs to match for the move to be a no-op.
  defp noop_move?(%Folder{parent_uuid: parent_uuid}, parent_uuid, nil), do: true

  defp noop_move?(%Folder{parent_uuid: parent_uuid, name: name}, parent_uuid, name), do: true

  defp noop_move?(%Folder{parent_uuid: parent_uuid, name: folder_name}, parent_uuid, name)
       when is_binary(name) do
    suffixed_variant?(folder_name, name)
  end

  defp noop_move?(_folder, _parent_uuid, _name), do: false

  defp suffixed_variant?(folder_name, name) do
    Regex.match?(~r/^#{Regex.escape(name)} \(\d+\)$/, folder_name)
  end

  defp build_ambiguous_duplicate_action(%{record: record, ambiguous: {f1, f2}}) do
    %{
      source: "catalogue",
      kind: :duplicate,
      label: record.name,
      op: :report,
      counts: nil,
      reason:
        "legacy folder found live in two places (#{f1.uuid} and #{f2.uuid}) — pick one and remove the other"
    }
  end

  defp build_shared_duplicate_action([%{folder: folder} | _] = group) do
    labels = group |> Enum.map(& &1.record.name) |> Enum.uniq() |> Enum.join(", ")

    %{
      source: "catalogue",
      kind: :duplicate,
      label: folder.name,
      op: :report,
      counts: nil,
      reason: "folder #{folder.uuid} is claimed by more than one record: #{labels}"
    }
  end

  defp pointer_uuid(%{data: data}) when is_map(data), do: Map.get(data, "files_folder_uuid")
  defp pointer_uuid(_), do: nil

  # X3: a pointer that is not a well-formed UUID is treated as absent,
  # never sent into an `in ^uuids` query (which would raise a CastError).
  defp valid_uuid(uuid) when is_binary(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, _} -> uuid
      :error -> nil
    end
  end

  defp valid_uuid(_), do: nil

  # One query for every distinct (valid) pointer uuid in the batch — live
  # folders only (X2).
  defp preload_by_uuid(uuids) do
    case uuids |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] ->
        %{}

      uuids ->
        Folder
        |> where([f], f.uuid in ^uuids and is_nil(f.trashed_at))
        |> repo().all()
        |> Map.new(&{&1.uuid, &1})
    end
  end

  # One query for every distinct legacy name in the batch, matching a live
  # folder ANYWHERE (any parent, including root) — not filtered to a
  # resolved parent, since the parent hook has not run yet for records
  # without another candidate. Grouped by name so more than one live match
  # (different parents) is visible to `resolve_entry/3` (X11). Live only
  # (X2 — the unique index is partial, a trashed twin must not hide the
  # live folder).
  defp preload_by_name_anywhere(names) do
    case names |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] ->
        %{}

      names ->
        Folder
        |> where([f], f.name in ^names and is_nil(f.trashed_at))
        |> repo().all()
        |> Enum.group_by(& &1.name)
    end
  end

  # `nil` when the pointer already matches the current (pre-move) folder —
  # nothing to back-fill. Otherwise a fun the engine runs after the move,
  # inside the same transaction, to write/repair the pointer. D7: writes
  # the owned jsonb key directly (locked row, plain changeset) — no
  # context `update_*`, no Activity log, no PubSub, no full validation.
  defp after_move_fun(record, pointer, %Folder{uuid: folder_uuid}) do
    if pointer == folder_uuid do
      nil
    else
      fn -> write_pointer(record, folder_uuid) end
    end
  end

  defp write_pointer(%Item{} = item, folder_uuid),
    do: write_pointer_directly(Item, item, folder_uuid)

  defp write_pointer(%Category{} = category, folder_uuid),
    do: write_pointer_directly(Category, category, folder_uuid)

  defp write_pointer(%Catalogue{} = catalogue, folder_uuid),
    do: write_pointer_directly(Catalogue, catalogue, folder_uuid)

  defp write_pointer_directly(schema, record, folder_uuid) do
    case locked(schema, record.uuid) do
      nil ->
        {:error, :not_found}

      current ->
        data = Map.put(current.data || %{}, "files_folder_uuid", folder_uuid)

        current
        |> Ecto.Changeset.change(data: data)
        |> repo().update()
        |> case do
          {:ok, _updated} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp locked(schema, uuid) do
    schema
    |> where([r], r.uuid == ^uuid)
    |> lock("FOR UPDATE")
    |> repo().one()
  end

  # ── Pending upload folders ──────────────────────────────────────

  # X4: a folder any live record currently points at is never independently
  # reported/trashed as a pending folder — its move (or duplicate report)
  # action above already covers it.
  defp pending_folder_actions(pending_days, claimed_uuids) do
    cutoff = DateTime.add(DateTime.utc_now(), -pending_days * 86_400, :second)

    folders =
      Folder
      |> where([f], is_nil(f.trashed_at))
      |> where([f], like(f.name, ^"#{@pending_prefix}%"))
      |> repo().all()
      |> Enum.reject(&MapSet.member?(claimed_uuids, &1.uuid))

    counts = counts_by_folder(Enum.map(folders, & &1.uuid))

    folders
    |> Enum.map(&pending_folder_action(&1, cutoff, counts))
    |> Enum.reject(&is_nil/1)
  end

  defp pending_folder_action(folder, cutoff, counts) do
    case folder_counts(counts, folder.uuid) do
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
  # record exists but was soft-deleted) is reported so a host can collect it.
  # Never `:move`d or `:trash`ed here — this module owns no "orphans"
  # container; a legacy folder that IS a live record's current folder is
  # left to `build_move_action/1` above.
  defp orphan_actions(resolved_parents) do
    case legacy_candidate_folders(resolved_parents) do
      [] ->
        []

      candidates ->
        records_by_key = load_candidate_records(candidates)
        counts = counts_by_folder(Enum.map(candidates, fn {folder, _kind} -> folder.uuid end))

        candidates
        |> Enum.map(&orphan_action(&1, records_by_key, counts))
        |> Enum.reject(&is_nil/1)
    end
  end

  # One SQL-filtered query (X6 — prefix filter in SQL, not loaded then
  # filtered in Elixir) for every live folder at root or under a resolved
  # parent whose name starts with the catalogue legacy prefix.
  defp legacy_candidate_folders(parent_uuids) do
    Folder
    |> where([f], is_nil(f.trashed_at))
    |> where([f], is_nil(f.parent_uuid) or f.parent_uuid in ^parent_uuids)
    |> where([f], like(f.name, ^"#{@legacy_prefix}%"))
    |> repo().all()
    |> Enum.map(&{&1, legacy_kind(&1.name)})
    |> Enum.filter(fn {_folder, kind} -> kind end)
  end

  defp legacy_kind(name) do
    if String.starts_with?(name, @pending_prefix) do
      nil
    else
      Enum.find_value(@legacy_kinds, &legacy_kind_match(name, &1))
    end
  end

  # X7: a strict UUID regex on the suffix (36-char canonical form) — not
  # `Ecto.UUID.cast/1`, which also accepts a raw 16-byte binary and would
  # key the map differently than the record's (lowercased) uuid.
  defp legacy_kind_match(name, {prefix, kind}) do
    if String.starts_with?(name, prefix) do
      suffix = String.replace_prefix(name, prefix, "")

      if Regex.match?(@uuid_regex, suffix) do
        {kind, String.downcase(suffix)}
      end
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

  defp orphan_action({folder, {kind, uuid}}, records_by_key, counts) do
    case Map.get(records_by_key, {kind, uuid}) do
      %{status: status} when status != "deleted" ->
        nil

      record ->
        folder_counts = folder_counts(counts, folder.uuid)

        %{
          source: "catalogue",
          kind: :orphan,
          op: :report,
          label: folder.name,
          folder: folder,
          counts: folder_counts,
          reason: orphan_reason(record, folder_counts)
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
  # `attach_to_pdf_library_folder/2` moduledoc comment). The `:pdf` hook is
  # only called when there is at least one root PDF to report (X12).
  defp pdf_report_actions(actor_uuid) do
    case root_pdf_count() do
      0 ->
        []

      count ->
        case Attachments.parent_folder_uuid(:pdf, actor_uuid) do
          folder_uuid when is_binary(folder_uuid) ->
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

          _ ->
            []
        end
    end
  end

  defp root_pdf_count do
    Pdf
    |> join(:inner, [p], f in File, on: f.uuid == p.file_uuid)
    |> where([p, f], p.status == "active" and f.status != "trashed" and is_nil(f.folder_uuid))
    |> repo().aggregate(:count)
  end

  # ── Shared helpers ───────────────────────────────────────────────

  # X1: two grouped queries (files by folder_uuid, links by folder_uuid)
  # for the whole plan's folder set — never a query per action. Counts ALL
  # rows regardless of status (including trashed files) — the core engine
  # re-measures the same way at apply time (any row with this
  # `folder_uuid`) and aborts the action on a mismatch, so a plan-time
  # count that excluded trashed files would fail every folder holding one.
  defp counts_by_folder(folder_uuids) do
    case Enum.uniq(folder_uuids) do
      [] ->
        {%{}, %{}}

      uuids ->
        files =
          File
          |> where([f], f.folder_uuid in ^uuids)
          |> group_by([f], f.folder_uuid)
          |> select([f], {f.folder_uuid, count(f.uuid)})
          |> repo().all()
          |> Map.new()

        links =
          FolderLink
          |> where([l], l.folder_uuid in ^uuids)
          |> group_by([l], l.folder_uuid)
          |> select([l], {l.folder_uuid, count(l.uuid)})
          |> repo().all()
          |> Map.new()

        {files, links}
    end
  end

  defp folder_counts({files, links}, folder_uuid) do
    {Map.get(files, folder_uuid, 0), Map.get(links, folder_uuid, 0)}
  end

  # Fills `counts: nil` placeholders left by `build_move_action/1` with a
  # single batched lookup across every `:move` action's folder — the whole
  # plan's move-folder counts come from one pair of grouped queries (X1),
  # not one pair per action.
  defp finalize_counts(actions) do
    counts =
      actions
      |> Enum.map(fn
        %{folder: %Folder{uuid: uuid}} -> uuid
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)
      |> counts_by_folder()

    Enum.map(actions, fn
      %{folder: %Folder{uuid: uuid}} = action -> %{action | counts: folder_counts(counts, uuid)}
      action -> action
    end)
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
