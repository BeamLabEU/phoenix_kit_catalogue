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

  Contract (design §9/§10 of `2026-09-15-media-reorganizer-design.md`):

    * **No configured `:attachments_parent_folder` hook → `:report`-only.**
      Orphan and pending-folder reports are still produced (informational,
      no writes); no `:move`, no `:trash`, no pointer back-fill happen.
    * **Claims are hook-independent.** Every live record's valid, live
      pointer folder is "claimed" regardless of whether a hook is
      configured — a pending folder any live record points at is never
      trashed, hook or no hook.
    * **A hook that raises, exits, or returns anything but `{:ok, uuid}` or
      an explicit `nil`** is a hook FAILURE: the record is skipped (no
      move planned for it) and counted into one `kind: :hook_error` report
      for the whole plan. Only an explicit `nil` means "root".
    * **Current-folder lookup mirrors `Attachments.find_resource_folder/2`:**
      host-named folder under the resolved parent, then the legacy
      deterministic name under the resolved parent, then the legacy name
      at root. A host-named folder found live IS the current folder
      (already-correct case — the plan then only needs a pointer
      back-fill). Host-named and legacy-named both live at once, two
      legacy matches (parent + root), or two records both actually
      resolving to the very same live folder are all unresolvable — each
      is a `kind: :duplicate` report, never a `:move`.
    * **A folder found through a record's live pointer keeps its own name**
      (never renamed) unless that name is still the legacy deterministic
      one — a record whose pointer folder still literally reads
      `catalogue-item-<uuid>` etc. gets the host name like any other
      candidate.
    * **A legacy-named folder live somewhere other than root or the
      resolved parent** (e.g. an old container from a previous layout) is
      left alone and reported `kind: :relocated` — never adopted or moved.
    * **Two records whose resolved *targets* would coincide** (same
      `{parent, desired name}`) are reported `kind: :duplicate` instead of
      both being planned as moves (the second would collide at apply
      time).
    * Only records that already have SOME live folder (a live pointer, or
      a folder anywhere matching the legacy name) are *candidates* — a
      record with neither never triggers a (possibly writing) host hook.

  Also covers stale `catalogue-attachment-pending-*` upload folders,
  orphaned legacy folders whose record is gone or deleted, and the shared
  PDF library folder — see the section comments below.
  """

  import Ecto.Query

  alias PhoenixKit.Modules.Storage.{Folder, FolderLink}
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
  Builds the catalogue's reorganizer plan. See the moduledoc for the full
  contract.

  `opts[:pending_days]` (default #{@default_pending_days}) — how old an
  empty pending folder must be before it is planned as `:trash` (or,
  without a configured hook, merely reported) instead of left alone.
  """
  @spec plan(String.t() | nil, keyword()) :: [map()]
  def plan(actor_uuid, opts \\ []) do
    pending_days = Keyword.get(opts, :pending_days, @default_pending_days)
    hook_on? = hook_configured?()

    tagged_records =
      tag(light_catalogues(), :catalogue) ++
        tag(light_categories(), :category) ++
        tag(light_items(), :item)

    # R1: independent of whether a hook is configured — a folder any live
    # record's pointer names is never a pending-trash/orphan candidate.
    pointer_claims = live_pointer_claims(tagged_records)

    {resource_actions, resolved_claims, resolved_parents} =
      if hook_on? do
        build_resource_plan(tagged_records, actor_uuid)
      else
        {[], claimed_folder_uuids([], [], [], []), []}
      end

    claimed_uuids = MapSet.union(pointer_claims, resolved_claims)

    resource_actions ++
      orphan_actions(resolved_parents, claimed_uuids) ++
      pending_folder_actions(pending_days, claimed_uuids, hook_on?) ++
      pdf_report_actions(actor_uuid)
  end

  # ── Catalogues / categories / items ─────────────────────────────

  defp hook_configured? do
    case Application.get_env(:phoenix_kit_catalogue, :attachments_parent_folder) do
      {mod, fun} when is_atom(mod) and is_atom(fun) ->
        Code.ensure_loaded?(mod) and
          (function_exported?(mod, fun, 3) or function_exported?(mod, fun, 2))

      _ ->
        false
    end
  end

  defp tag(records, kind), do: Enum.map(records, &{&1, kind})

  # E1/D1: candidate detection needs no hook call, so build_resource_plan
  # is only reached at all when a parent hook is configured (see plan/2).
  # Even then, a record with no existing live folder (pointer or legacy
  # name) never triggers the host's (possibly writing) hooks.
  defp build_resource_plan(tagged_records, actor_uuid) do
    {mod, fun} = Application.get_env(:phoenix_kit_catalogue, :attachments_parent_folder)

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

    {resolved_all, hook_error_count} =
      resolve_candidates(candidates, by_pointer, by_name, mod, fun, actor_uuid)

    {relocated, resolved} = Enum.split_with(resolved_all, & &1.relocated)
    relocated_actions = Enum.map(relocated, &build_relocated_action/1)

    # A record whose current folder was resolved (via pointer or a
    # host/legacy match) can still leave a SEPARATE legacy-named folder
    # live somewhere else entirely (e.g. an old third-party container) —
    # that stray twin is neither this record's current folder nor an
    # orphan (the record is alive), so it gets its own `:relocated`
    # report alongside whatever action the record itself gets.
    stray_actions =
      resolved
      |> Enum.filter(& &1.stray_legacy)
      |> Enum.map(&build_relocated_action(%{&1 | relocated: &1.stray_legacy}))

    resolved_parents =
      resolved |> Enum.map(& &1.parent_uuid) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    {ambiguous, normal} = Enum.split_with(resolved, & &1.ambiguous)
    {with_folder, _without_folder} = Enum.split_with(normal, & &1.folder)

    {shared, unique} = split_shared(with_folder)
    {converging, solo} = split_converging(unique)

    move_actions = solo |> Enum.map(&build_move_action/1) |> Enum.reject(&is_nil/1)
    dup_actions = Enum.map(ambiguous, &build_ambiguous_duplicate_action/1)
    shared_actions = Enum.map(shared, &build_shared_duplicate_action/1)
    converging_actions = Enum.map(converging, &build_converging_duplicate_action/1)
    hook_error_actions = hook_error_action(hook_error_count)

    all_actions =
      move_actions ++
        dup_actions ++
        shared_actions ++
        converging_actions ++ relocated_actions ++ stray_actions ++ hook_error_actions

    claimed = claimed_folder_uuids(unique, ambiguous, shared, converging)

    {finalize_counts(all_actions), claimed, resolved_parents}
  end

  # R2: resolves the desired parent for every candidate via the host's
  # exact hook, distinguishing an explicit `nil` (root) from a hook that
  # raised/exited/returned anything else (failure — the record is
  # skipped, never treated as "root"). Only candidates with a live
  # pointer folder are separated from the rest (`pointer_track`) — those
  # never need the batched host-name-under-parent lookup (R3/R8) that the
  # remaining candidates (`name_track`) do.
  defp resolve_candidates(candidates, by_pointer, by_name, mod, fun, actor_uuid) do
    {pointer_track, name_track, hook_error_count} =
      Enum.reduce(candidates, {[], [], 0}, fn p, acc ->
        sort_candidate(p, by_pointer, mod, fun, actor_uuid, acc)
      end)

    pointer_entries =
      pointer_track |> Enum.reverse() |> Enum.map(&resolve_pointer_entry(&1, by_name, actor_uuid))

    name_entries = resolve_name_entries(Enum.reverse(name_track), by_name, actor_uuid)

    {pointer_entries ++ name_entries, hook_error_count}
  end

  defp sort_candidate(p, by_pointer, mod, fun, actor_uuid, {ptrs, names, errs}) do
    case resolve_parent(mod, fun, p.kind, actor_uuid, p.record) do
      {:ok, parent_uuid} ->
        base = Map.put(p, :parent_uuid, parent_uuid)
        pointer_folder = p.pointer && Map.get(by_pointer, p.pointer)
        push_candidate(base, pointer_folder, ptrs, names, errs)

      :error ->
        {ptrs, names, errs + 1}
    end
  end

  defp push_candidate(base, nil, ptrs, names, errs), do: {ptrs, [base | names], errs}

  defp push_candidate(base, pointer_folder, ptrs, names, errs),
    do: {[Map.put(base, :pointer_folder, pointer_folder) | ptrs], names, errs}

  defp resolve_parent(mod, fun, kind, actor_uuid, resource) do
    cond do
      Code.ensure_loaded?(mod) and function_exported?(mod, fun, 3) ->
        guarded_hook_call(fn -> apply(mod, fun, [kind, actor_uuid, resource]) end)

      Code.ensure_loaded?(mod) and function_exported?(mod, fun, 2) ->
        guarded_hook_call(fn -> apply(mod, fun, [kind, actor_uuid]) end)

      true ->
        :error
    end
  end

  defp guarded_hook_call(fun) do
    case fun.() do
      {:ok, uuid} when is_binary(uuid) -> {:ok, uuid}
      {:ok, nil} -> {:ok, nil}
      nil -> {:ok, nil}
      _other -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  # D6/E2: a folder found through the record's live pointer keeps its own
  # name — UNLESS that name is still the legacy deterministic one, in
  # which case it gets the host name like any other candidate (R8: the
  # name hook is skipped entirely otherwise).
  defp resolve_pointer_entry(%{pointer_folder: folder} = d, by_name, actor_uuid) do
    name = if folder.name == d.legacy_name, do: safe_folder_name(d.record, actor_uuid)

    %{
      record: d.record,
      kind: d.kind,
      pointer: d.pointer,
      legacy_name: d.legacy_name,
      parent_uuid: d.parent_uuid,
      name: name,
      folder: folder,
      via: :pointer,
      ambiguous: nil,
      relocated: nil,
      stray_legacy: stray_legacy_twin(d.legacy_name, by_name, folder.uuid)
    }
  end

  # A legacy-named folder live somewhere else while the pointer already
  # names the record's real current folder — not this record's current
  # folder, and not an orphan either (the record is alive) — reported so
  # it never goes permanently unseen.
  defp stray_legacy_twin(legacy_name, by_name, current_folder_uuid) do
    by_name
    |> Map.get(legacy_name, [])
    |> Enum.find(&(&1.uuid != current_folder_uuid))
  end

  # R3: the module's own lookup order for a record with no live pointer —
  # host-named folder under the resolved parent, then the legacy name
  # under the resolved parent, then the legacy name at root. Host-named
  # and legacy-named both live at once (or two legacy matches) are
  # unresolvable duplicates. A legacy match that is live under neither
  # the resolved parent nor root is left alone and reported `:relocated`.
  defp resolve_name_entries(candidates, by_name, actor_uuid) do
    with_host_name =
      Enum.map(candidates, &Map.put(&1, :host_name, safe_folder_name(&1.record, actor_uuid)))

    host_map = preload_host_named_under_parent(with_host_name)

    Enum.map(with_host_name, &resolve_name_entry(&1, by_name, host_map))
  end

  defp preload_host_named_under_parent(entries) do
    pairs =
      entries
      |> Enum.filter(& &1.parent_uuid)
      |> Enum.map(&{&1.parent_uuid, &1.host_name})
      |> Enum.uniq()

    case pairs do
      [] ->
        %{}

      pairs ->
        parents = pairs |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
        names = pairs |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

        Folder
        |> where([f], is_nil(f.trashed_at) and f.parent_uuid in ^parents and f.name in ^names)
        |> repo().all()
        |> Enum.filter(&({&1.parent_uuid, &1.name} in pairs))
        |> Map.new(&{{&1.parent_uuid, &1.name}, &1})
    end
  end

  defp resolve_name_entry(d, by_name, host_map) do
    host_folder = d.parent_uuid && Map.get(host_map, {d.parent_uuid, d.host_name})
    matches = Map.get(by_name, d.legacy_name, [])
    under_parent = d.parent_uuid && Enum.find(matches, &(&1.parent_uuid == d.parent_uuid))
    at_root = Enum.find(matches, &is_nil(&1.parent_uuid))
    legacy_folder = under_parent || at_root

    base = %{
      record: d.record,
      kind: d.kind,
      pointer: d.pointer,
      legacy_name: d.legacy_name,
      parent_uuid: d.parent_uuid,
      folder: nil,
      via: nil,
      name: nil,
      ambiguous: nil,
      relocated: nil,
      stray_legacy: nil
    }

    # A third match — live under neither the resolved parent nor root —
    # left over once the chosen `legacy_folder` (if any) is accounted
    # for. Only meaningful for the "host wins" / "legacy wins" branches
    # below; the ambiguous/relocated branches already consume every
    # match into their own report.
    stray_legacy = Enum.find(matches, &(&1 != legacy_folder))

    resolve_name_entry_result(
      base,
      d.host_name,
      host_folder,
      legacy_folder,
      under_parent,
      at_root,
      matches,
      stray_legacy
    )
  end

  defp resolve_name_entry_result(
         base,
         _host_name,
         host_folder,
         legacy_folder,
         _under,
         _root,
         _matches,
         _stray
       )
       when not is_nil(host_folder) and not is_nil(legacy_folder) and
              host_folder.uuid != legacy_folder.uuid do
    %{base | ambiguous: {host_folder, legacy_folder}}
  end

  defp resolve_name_entry_result(
         base,
         _host_name,
         _host_folder,
         _legacy_folder,
         under_parent,
         at_root,
         _matches,
         _stray
       )
       when not is_nil(under_parent) and not is_nil(at_root) do
    %{base | ambiguous: {under_parent, at_root}}
  end

  # R3/E6-class fix: a host-named folder wins as the current folder, but a
  # SEPARATE legacy-named match lives under some third parent (neither
  # root nor the resolved parent) — that leftover gets its own
  # `:relocated` report so it is never silently dropped.
  defp resolve_name_entry_result(
         base,
         host_name,
         host_folder,
         _legacy_folder,
         _under,
         _root,
         _matches,
         stray_legacy
       )
       when not is_nil(host_folder) do
    %{base | folder: host_folder, via: :name, name: host_name, stray_legacy: stray_legacy}
  end

  defp resolve_name_entry_result(
         base,
         host_name,
         _host_folder,
         legacy_folder,
         _under,
         _root,
         _matches,
         stray_legacy
       )
       when not is_nil(legacy_folder) do
    %{base | folder: legacy_folder, via: :name, name: host_name, stray_legacy: stray_legacy}
  end

  defp resolve_name_entry_result(
         base,
         _host_name,
         _host_folder,
         _legacy_folder,
         _under,
         _root,
         [first | _],
         _stray
       ) do
    %{base | relocated: first}
  end

  defp resolve_name_entry_result(
         base,
         _host_name,
         _host_folder,
         _legacy_folder,
         _under,
         _root,
         [],
         _stray
       ),
       do: base

  # Splits entries whose current folder is claimed by exactly one record
  # (`unique`) from those two or more records resolve to the very same
  # live folder (`shared`, X5) — order-preserving (a plain `group_by`
  # would scramble R10's enumeration order).
  defp split_shared(entries) do
    freq = Enum.frequencies_by(entries, & &1.folder.uuid)
    {shared_entries, unique} = Enum.split_with(entries, &(Map.get(freq, &1.folder.uuid) > 1))
    shared_groups = shared_entries |> Enum.group_by(& &1.folder.uuid) |> Map.values()
    {shared_groups, unique}
  end

  # R7/E3: two records whose *desired* target (parent + name, or parent +
  # the folder's own kept name when `name` is nil) coincide — the second
  # move would collide with the first at apply time.
  defp split_converging(entries) do
    freq = Enum.frequencies_by(entries, &convergence_key/1)

    {converging_entries, solo} =
      Enum.split_with(entries, &(Map.get(freq, convergence_key(&1)) > 1))

    converging_groups = converging_entries |> Enum.group_by(&convergence_key/1) |> Map.values()
    {converging_groups, solo}
  end

  defp convergence_key(entry), do: {entry.parent_uuid, entry.name || entry.folder.name}

  defp claimed_folder_uuids(unique, ambiguous, shared_groups, converging_groups) do
    unique_uuids = Enum.map(unique, & &1.folder.uuid)

    ambiguous_uuids =
      Enum.flat_map(ambiguous, fn %{ambiguous: {f1, f2}} -> [f1.uuid, f2.uuid] end)

    shared_uuids = Enum.flat_map(shared_groups, fn [%{folder: f} | _] -> [f.uuid] end)

    converging_uuids =
      Enum.flat_map(converging_groups, fn group -> Enum.map(group, & &1.folder.uuid) end)

    MapSet.new(unique_uuids ++ ambiguous_uuids ++ shared_uuids ++ converging_uuids)
  end

  # A `:move` whose folder already sits at `parent_uuid` under `name` (or
  # an accepted `"name (N)"` suffix variant) and needs no pointer back-fill
  # is a no-op — filtered here (this Source has no core `Action.noop?/1`
  # to lean on; the core engine only filters `after_move: nil` no-ops
  # coming out of a `Source`).
  defp build_move_action(entry) do
    move_action(entry, entry.name)
  end

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
        "folder found live in two places (#{f1.uuid} and #{f2.uuid}) — pick one and remove the other"
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

  defp build_converging_duplicate_action([entry | _] = group) do
    labels = group |> Enum.map(& &1.record.name) |> Enum.uniq() |> Enum.join(", ")
    {parent_uuid, name} = convergence_key(entry)
    parent_label = parent_uuid || "root"

    %{
      source: "catalogue",
      kind: :duplicate,
      label: labels,
      op: :report,
      counts: nil,
      reason:
        "multiple records would move to the same destination (parent #{parent_label}, name #{name}): #{labels}"
    }
  end

  defp build_relocated_action(%{record: record, kind: kind, relocated: folder}) do
    %{
      source: "catalogue",
      kind: :relocated,
      op: :report,
      label: record.name,
      folder: folder,
      counts: nil,
      reason:
        "legacy folder #{folder.uuid} (#{kind}) is live under a different parent — left alone, never adopted"
    }
  end

  # Defensive: `Attachments.folder_name/2` already falls back to the
  # deterministic legacy name when the host hook is missing or returns an
  # invalid value; this only guards against the hook itself raising.
  defp safe_folder_name(record, actor_uuid) do
    Attachments.folder_name(record, actor_uuid)
  rescue
    _ -> Attachments.legacy_folder_name(record)
  catch
    _, _ -> Attachments.legacy_folder_name(record)
  end

  defp pointer_uuid(%{data: data}) when is_map(data), do: Map.get(data, "files_folder_uuid")
  defp pointer_uuid(_), do: nil

  # R5/X3: a pointer that is not a well-formed UUID is treated as absent,
  # never sent into an `in ^uuids` query (which would raise a CastError).
  # Returns the CAST/downcased value — not the raw string — so an
  # upper-case pointer still matches the (lower-case) keys `by_pointer`
  # and the live-claims set are keyed by.
  defp valid_uuid(uuid) when is_binary(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, cast} -> cast
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
  # (different parents) is visible downstream. Live only (X2 — the unique
  # index is partial, a trashed twin must not hide the live folder).
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

  # R1: every valid, live pointer of every LIVE record — independent of
  # whether a parent hook is configured. Used only to keep a claimed
  # folder out of the pending-trash/orphan sweeps; never triggers a hook.
  defp live_pointer_claims(tagged_records) do
    pointers =
      tagged_records
      |> Enum.map(fn {record, _kind} -> valid_uuid(pointer_uuid(record)) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Folder
    |> where([f], f.uuid in ^pointers and is_nil(f.trashed_at))
    |> select([f], f.uuid)
    |> repo().all()
    |> MapSet.new()
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

  # Re-checks the record under `FOR UPDATE` at apply time: gone or
  # soft-deleted since the plan was built aborts the back-fill instead of
  # pointing a live-looking record at a folder nobody will ever see again.
  defp write_pointer_directly(schema, record, folder_uuid) do
    case locked(schema, record.uuid) do
      nil ->
        {:error, :not_found}

      %{status: "deleted"} ->
        {:error, :record_deleted}

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

  defp hook_error_action(0), do: []

  defp hook_error_action(count) do
    [
      %{
        source: "catalogue",
        kind: :hook_error,
        op: :report,
        label: "attachments parent hook",
        counts: nil,
        reason:
          "#{count} record(s) skipped: the configured parent hook raised, exited, or " <>
            "returned neither {:ok, uuid} nor nil"
      }
    ]
  end

  # ── Pending upload folders ──────────────────────────────────────

  # X4/R1: a folder any live record currently points at is never
  # independently reported/trashed as a pending folder — its move (or
  # duplicate report) action, if any, already covers it, and `claimed`
  # includes the hook-independent pointer claims regardless.
  defp pending_folder_actions(pending_days, claimed_uuids, hook_on?) do
    cutoff = DateTime.add(DateTime.utc_now(), -pending_days * 86_400, :second)

    folders =
      Folder
      |> where([f], is_nil(f.trashed_at))
      |> where([f], like(f.name, ^"#{@pending_prefix}%"))
      |> repo().all()
      |> Enum.reject(&MapSet.member?(claimed_uuids, &1.uuid))

    counts = counts_by_folder(Enum.map(folders, & &1.uuid))
    files_by_folder = pending_files_by_folder(Enum.map(folders, & &1.uuid))

    folders
    |> Enum.map(&pending_folder_action(&1, cutoff, counts, files_by_folder, hook_on?))
    |> Enum.reject(&is_nil/1)
  end

  defp pending_folder_action(folder, cutoff, counts, files_by_folder, hook_on?) do
    case folder_counts(counts, folder.uuid) do
      {0, 0} ->
        if DateTime.compare(folder.inserted_at, cutoff) == :lt do
          pending_stale_action(folder, hook_on?)
        end

      {files, links} ->
        %{
          source: "catalogue",
          kind: :pending,
          label: folder.name,
          op: :report,
          folder: folder,
          counts: {files, links},
          reason: "pending folder still has #{pending_reason(folder.uuid, files_by_folder)}"
        }
    end
  end

  # E1: without a configured hook, a stale empty pending folder is
  # reported, never trashed.
  defp pending_stale_action(folder, true) do
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

  defp pending_stale_action(folder, false) do
    %{
      source: "catalogue",
      kind: :pending,
      label: folder.name,
      op: :report,
      folder: folder,
      counts: {0, 0},
      reason:
        "empty pending upload folder older than the retention window " <>
          "(no attachments hook configured — not trashed)"
    }
  end

  # R6: one batched query (home files + linked files) for every non-empty
  # pending folder in the batch — never a query per folder. R6: the
  # reason is never empty — a folder whose only files are trashed says so
  # explicitly instead of rendering an empty file list.
  defp pending_files_by_folder(folder_uuids) do
    case folder_uuids do
      [] ->
        %{}

      uuids ->
        home_rows =
          PhoenixKit.Modules.Storage.File
          |> where([f], f.folder_uuid in ^uuids)
          |> select([f], {f.folder_uuid, f.original_file_name, f.status})
          |> repo().all()

        linked_rows =
          FolderLink
          |> join(:inner, [l], f in PhoenixKit.Modules.Storage.File, on: f.uuid == l.file_uuid)
          |> where([l, _f], l.folder_uuid in ^uuids)
          |> select([l, f], {l.folder_uuid, f.original_file_name, f.status})
          |> repo().all()

        Enum.group_by(home_rows ++ linked_rows, fn {folder_uuid, _name, _status} ->
          folder_uuid
        end)
    end
  end

  defp pending_reason(folder_uuid, files_by_folder) do
    rows = Map.get(files_by_folder, folder_uuid, [])

    live_names =
      rows
      |> Enum.reject(fn {_f, _n, status} -> status == "trashed" end)
      |> Enum.map(&elem(&1, 1))

    case live_names do
      [] -> "#{length(rows)} trashed file(s)"
      names -> "files: #{Enum.join(names, ", ")}"
    end
  end

  # ── Orphaned legacy folders ──────────────────────────────────────

  # A legacy-named folder (`catalogue-item-<uuid>`, `catalogue-category-<uuid>`,
  # `catalogue-<uuid>`) at the media root or under a parent this batch's hooks
  # resolved to, whose uuid no longer names a live record (missing, or the
  # record exists but was soft-deleted) is reported so a host can collect it.
  # Never `:move`d or `:trash`ed here — this module owns no "orphans"
  # container; a legacy folder claimed by a live record (its current
  # folder, a duplicate, or a converging-target group) is excluded (R4 —
  # one folder gets at most one action).
  defp orphan_actions(resolved_parents, claimed_uuids) do
    case legacy_candidate_folders(resolved_parents, claimed_uuids) do
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
  defp legacy_candidate_folders(parent_uuids, claimed_uuids) do
    Folder
    |> where([f], is_nil(f.trashed_at))
    |> where([f], is_nil(f.parent_uuid) or f.parent_uuid in ^parent_uuids)
    |> where([f], like(f.name, ^"#{@legacy_prefix}%"))
    |> repo().all()
    |> Enum.reject(&MapSet.member?(claimed_uuids, &1.uuid))
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

  # One query per record kind present among the candidates — not per
  # folder — and only the status column (R9): an orphan report needs
  # nothing else off the record.
  defp load_candidate_records(candidates) do
    by_kind =
      Enum.group_by(
        candidates,
        fn {_folder, {kind, _uuid}} -> kind end,
        fn {_folder, {_kind, uuid}} -> uuid end
      )

    %{}
    |> Map.merge(load_record_statuses(Item, :item, Map.get(by_kind, :item, [])))
    |> Map.merge(load_record_statuses(Category, :category, Map.get(by_kind, :category, [])))
    |> Map.merge(load_record_statuses(Catalogue, :catalogue, Map.get(by_kind, :catalogue, [])))
  end

  defp load_record_statuses(_schema, _kind, []), do: %{}

  defp load_record_statuses(schema, kind, uuids) do
    schema
    |> where([r], r.uuid in ^uuids)
    |> select([r], {r.uuid, r.status})
    |> repo().all()
    |> Map.new(fn {uuid, status} -> {{kind, uuid}, status} end)
  end

  defp orphan_action({folder, {kind, uuid}}, records_by_key, counts) do
    case Map.get(records_by_key, {kind, uuid}) do
      status when is_binary(status) and status != "deleted" ->
        nil

      status ->
        folder_counts = folder_counts(counts, folder.uuid)

        %{
          source: "catalogue",
          kind: :orphan,
          op: :report,
          label: folder.name,
          folder: folder,
          counts: folder_counts,
          reason: orphan_reason(status, folder_counts)
        }
    end
  end

  defp orphan_reason(nil, {files, _links}), do: "record missing, #{files} file(s)"
  defp orphan_reason(status, {files, _links}), do: "record status #{status}, #{files} file(s)"

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
    |> join(:inner, [p], f in PhoenixKit.Modules.Storage.File, on: f.uuid == p.file_uuid)
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
          PhoenixKit.Modules.Storage.File
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

  # R9/R10: only the columns a plan needs (never the full jsonb-heavy
  # row), ordered catalogue-then-category-then-item, each by
  # `inserted_at`/`uuid` — a deterministic, readable report order.
  defp light_catalogues do
    Catalogue
    |> where([c], c.status != "deleted")
    |> order_by([c], asc: c.inserted_at, asc: c.uuid)
    |> select([c], struct(c, [:uuid, :name, :status, :data, :inserted_at]))
    |> repo().all()
  end

  defp light_categories do
    Category
    |> where([c], c.status != "deleted")
    |> order_by([c], asc: c.inserted_at, asc: c.uuid)
    |> select([c], struct(c, [:uuid, :name, :status, :data, :catalogue_uuid, :inserted_at]))
    |> repo().all()
  end

  defp light_items do
    Item
    |> where([i], i.status != "deleted")
    |> order_by([i], asc: i.inserted_at, asc: i.uuid)
    |> select(
      [i],
      struct(i, [:uuid, :name, :status, :data, :catalogue_uuid, :category_uuid, :inserted_at])
    )
    |> repo().all()
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
