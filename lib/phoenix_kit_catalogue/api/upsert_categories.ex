defmodule PhoenixKitCatalogue.API.UpsertCategories do
  @moduledoc false
  # Tool `catalogue.upsert_categories` (spec 6.1, 5.4). Rows are processed in
  # order, in both modes: a parent created earlier in the request is findable
  # later in it (in the database when executing, in `state.planned` when
  # previewing). A preview also models the two ways an update fails at write
  # time (an external_id another category holds, a parent that would make a
  # cycle) so that it does not promise a row that will fail.

  alias PhoenixKitCatalogue.API
  alias PhoenixKitCatalogue.API.{Common, Refs}
  alias PhoenixKitCatalogue.Catalogue

  @tool "catalogue.upsert_categories"
  @external_id_path ["api", "external_id"]

  @spec call(map(), map()) ::
          {:ok, map()} | {:preview, map(), String.t()} | {:error, atom(), String.t(), map()}
  def call(input, ctx) do
    with :ok <- Common.ensure_schema(),
         {:ok, catalogue} <- API.resolve_catalogue(input["catalogue_id"], writable: true) do
      mode = if ctx.dry_run?, do: :preview, else: :execute
      opts = Common.write_opts(ctx, @tool)

      {rows, _state} =
        Enum.map_reduce(input["items"], %{planned: MapSet.new(), parents: nil}, fn row, state ->
          process(row, state, catalogue, mode, opts)
        end)

      if mode == :preview, do: Common.preview(rows), else: Common.batch_result(rows)
    end
  end

  defp process(row, state, catalogue, mode, opts) do
    ref = Map.take(row, ["id", "external_id"])

    with :ok <- check_reference(row),
         :ok <- check_name(row),
         {:ok, existing} <- find_existing(row, catalogue, state),
         {:ok, parent} <- find_parent(row, catalogue, state) do
      case existing do
        {:category, category} -> update(ref, row, category, parent, catalogue, state, mode, opts)
        :planned -> {Common.row_ok(ref, "unchanged", nil), state}
        :none -> create(ref, row, parent, catalogue, state, mode, opts)
      end
    else
      {:error, code, message, context} -> {Common.row_error(ref, code, message, context), state}
    end
  end

  # Row-level strings have no length floor in the schema (see `Schemas`): a
  # blank external_id is this row's error. A malformed `id` falls through to
  # `find_existing/3`, where `Refs` answers `not_found`.
  defp check_reference(%{"id" => _, "external_id" => eid}) do
    if Common.blank?(eid), do: invalid("external_id", "must not be blank"), else: :ok
  end

  defp check_reference(%{"id" => _}), do: :ok

  defp check_reference(%{"external_id" => eid}) do
    if Common.blank?(eid), do: invalid("external_id", "must not be blank"), else: :ok
  end

  defp check_reference(_row),
    do: invalid("id", "give the category's id or its external_id")

  defp check_name(%{"name" => name}) do
    if Common.blank?(name), do: invalid("name", "must not be blank"), else: :ok
  end

  defp check_name(_row), do: :ok

  defp invalid(path, message),
    do:
      {:error, :validation_failed, message,
       %{"errors" => [%{"path" => path, "message" => message}]}}

  # --- finding things -------------------------------------------------------------------

  defp find_existing(%{"id" => id}, catalogue, _state) do
    case lookup(%{"id" => id}, catalogue) do
      {:ok, category} ->
        {:ok, {:category, category}}

      {:error, :not_found} ->
        {:error, :not_found,
         "No category has this id; to create one, give an external_id and no id.", %{}}

      {:error, other} ->
        lookup_error(other, "id")
    end
  end

  defp find_existing(%{"external_id" => eid}, catalogue, state) do
    case lookup(%{"external_id" => eid}, catalogue) do
      {:ok, category} ->
        {:ok, {:category, category}}

      {:error, :not_found} ->
        if MapSet.member?(state.planned, eid), do: {:ok, :planned}, else: {:ok, :none}

      {:error, other} ->
        lookup_error(other, "external_id")
    end
  end

  # `parent`: absent keeps it (`:keep`), `nil` is the top level, a reference is
  # resolved among this catalogue's categories (or the request's own, in a preview).
  defp find_parent(row, catalogue, state) do
    case Map.fetch(row, "parent") do
      :error -> {:ok, :keep}
      {:ok, nil} -> {:ok, nil}
      {:ok, ref} -> resolve_parent(ref, catalogue, state)
    end
  end

  defp resolve_parent(ref, catalogue, state) do
    case lookup(ref, catalogue) do
      {:ok, parent} -> {:ok, parent.uuid}
      {:error, :not_found} -> planned_parent(ref, state)
      {:error, other} -> lookup_error(other, "parent")
    end
  end

  defp planned_parent(ref, state) do
    if planned?(state, ref) do
      {:ok, :planned}
    else
      {:error, :not_found, "The parent category was not found in this catalogue.",
       %{"errors" => [%{"path" => "parent", "message" => "not found"}]}}
    end
  end

  defp planned?(state, %{"external_id" => eid}), do: MapSet.member?(state.planned, eid)
  defp planned?(_state, _ref), do: false

  defp lookup(ref, catalogue) do
    case API.resolve_refs([ref], kind: :category, catalogue_uuid: catalogue.uuid) do
      [{_ref, {:ok, category}}] -> {:ok, category}
      [{_ref, {:error, reason}}] -> {:error, reason}
    end
  end

  defp lookup_error(:invalid_ref, "parent"),
    do: invalid("parent", "give exactly one of id or external_id")

  defp lookup_error(:invalid_ref, path), do: invalid(path, "must not be blank")

  defp lookup_error({:ambiguous_ref, ids}, _path),
    do:
      {:error, :ambiguous_ref, "The reference matches several categories.",
       %{"candidates" => ids}}

  # --- update -----------------------------------------------------------------------------

  defp update(ref, row, category, parent, catalogue, state, mode, opts) do
    {attrs, changes} = diff(row, category, parent)
    {attrs, changes, eid_change?} = with_external_id(attrs, changes, row, category)

    cond do
      changes == %{} ->
        {Common.row_ok(ref, "unchanged", category.uuid), state}

      mode == :preview ->
        preview_update(ref, row, category, attrs, changes, eid_change?, catalogue, state)

      true ->
        write_opts =
          if eid_change?,
            do:
              opts ++
                [data_owned_paths: [@external_id_path], logged_data_paths: [@external_id_path]],
            else: opts

        case Catalogue.update_category(category, attrs, write_opts) do
          {:ok, _updated} ->
            {Common.row_ok(ref, "updated", category.uuid), state}

          {:error, %Ecto.Changeset{} = changeset} ->
            {failure(ref, changeset, row, catalogue), state}

          {:error, :not_found} ->
            {Common.row_error(ref, :not_found, "The category no longer exists."), state}

          {:error, _reason} ->
            {Common.row_error(ref, :internal_error, "The category could not be written."), state}
        end
    end
  end

  defp preview_update(ref, row, category, attrs, changes, eid_change?, catalogue, state) do
    state = load_parents(state, catalogue)
    reparent? = Map.has_key?(attrs, :parent_uuid)

    cond do
      eid_change? and external_id_held?(row["external_id"], category, catalogue, state) ->
        {external_id_taken(ref, holder_of(row["external_id"], catalogue)), state}

      reparent? and parent_problem(state.parents, category.uuid, attrs.parent_uuid) ->
        message = parent_problem(state.parents, category.uuid, attrs.parent_uuid)

        {Common.row_error(ref, :validation_failed, "The category is not valid.", %{
           "errors" => [%{"path" => "parent_uuid", "message" => message}]
         }), state}

      true ->
        parents =
          if reparent?,
            do: Map.put(state.parents, category.uuid, attrs.parent_uuid),
            else: state.parents

        {Common.row_ok(ref, "updated", category.uuid, %{"changes" => changes}),
         %{state | parents: parents}}
    end
  end

  defp external_id_held?(eid, category, catalogue, state) do
    MapSet.member?(state.planned, eid) or
      match?(holder when is_binary(holder) and holder != category.uuid, holder_of(eid, catalogue))
  end

  # The parent of every live category, read once per preview and kept current
  # as the preview re-parents rows, so that a cycle made by two rows of the
  # same request is seen like the sequential writes would see it.
  defp load_parents(%{parents: nil} = state, catalogue) do
    parents =
      catalogue.uuid
      |> Catalogue.list_categories_metadata_for_catalogue()
      |> Map.new(&{&1.uuid, &1.parent_uuid})

    %{state | parents: parents}
  end

  defp load_parents(state, _catalogue), do: state

  defp parent_problem(_parents, _own, nil), do: nil
  defp parent_problem(_parents, own, own), do: "category cannot be its own parent"

  defp parent_problem(parents, own, candidate) do
    if descends_from?(parents, candidate, own, MapSet.new()), do: "would create a cycle"
  end

  # Whether walking up from `current` reaches `own`.
  defp descends_from?(_parents, nil, _own, _seen), do: false
  defp descends_from?(_parents, own, own, _seen), do: true

  defp descends_from?(parents, current, own, seen) do
    if MapSet.member?(seen, current),
      do: false,
      else: descends_from?(parents, Map.get(parents, current), own, MapSet.put(seen, current))
  end

  # The fields that differ, as column attrs and as a from/to map for the log and the preview.
  defp diff(row, category, parent) do
    [
      {"name", :name, category.name, row["name"], Map.has_key?(row, "name")},
      {"position", :position, category.position, row["position"], Map.has_key?(row, "position")},
      {"parent_id", :parent_uuid, category.parent_uuid, parent, parent != :keep}
    ]
    |> Enum.reduce({%{}, %{}}, fn {key, field, old, new, given?}, {attrs, changes} ->
      cond do
        not given? or new == old ->
          {attrs, changes}

        new == :planned ->
          {attrs,
           Map.put(changes, key, %{
             "from" => show(old),
             "to" => "(a category created earlier in this request)"
           })}

        true ->
          {Map.put(attrs, field, new),
           Map.put(changes, key, %{"from" => show(old), "to" => show(new)})}
      end
    end)
  end

  defp show(nil), do: ""
  defp show(value) when is_binary(value), do: value
  defp show(value), do: to_string(value)

  # id AND external_id given, and the stored external id differs: set it.
  defp with_external_id(attrs, changes, %{"id" => _, "external_id" => eid}, category) do
    if Refs.external_id(category) == eid do
      {attrs, changes, false}
    else
      {Map.put(attrs, :data, %{"api" => %{"external_id" => eid}}),
       Map.put(changes, "data.api.external_id", %{
         "from" => show(Refs.external_id(category)),
         "to" => eid
       }), true}
    end
  end

  defp with_external_id(attrs, changes, _row, _category), do: {attrs, changes, false}

  # --- create -----------------------------------------------------------------------------

  defp create(ref, row, parent, catalogue, state, mode, opts) do
    cond do
      Common.blank?(row["name"]) ->
        {Common.row_error(ref, :validation_failed, "A name is required to create a category.", %{
           "errors" => [%{"path" => "name", "message" => "is required to create a category"}]
         }), state}

      mode == :preview ->
        fields = %{"name" => String.trim(row["name"]), "external_id" => row["external_id"]}

        fields =
          if parent in [:keep, nil],
            do: fields,
            else: Map.put(fields, "parent", show_parent(parent))

        fields =
          if row["position"], do: Map.put(fields, "position", row["position"]), else: fields

        {Common.row_ok(ref, "created", nil, %{"fields" => fields}),
         %{state | planned: MapSet.put(state.planned, row["external_id"])}}

      true ->
        case Catalogue.create_category(create_attrs(row, parent, catalogue), opts) do
          {:ok, category} ->
            {Common.row_ok(ref, "created", category.uuid), state}

          {:error, %Ecto.Changeset{} = changeset} ->
            {failure(ref, changeset, row, catalogue), state}
        end
    end
  end

  defp show_parent(:planned), do: "(a category created earlier in this request)"
  defp show_parent(uuid), do: uuid

  defp create_attrs(row, parent, catalogue) do
    %{
      name: String.trim(row["name"]),
      catalogue_uuid: catalogue.uuid,
      data: %{"api" => %{"external_id" => row["external_id"]}}
    }
    |> then(&if(is_binary(parent), do: Map.put(&1, :parent_uuid, parent), else: &1))
    |> then(&if(row["position"], do: Map.put(&1, :position, row["position"]), else: &1))
  end

  # --- failures -----------------------------------------------------------------------------

  defp failure(ref, changeset, row, catalogue) do
    if Common.external_id_conflict?(changeset) do
      external_id_taken(ref, holder_of(row["external_id"], catalogue))
    else
      Common.row_error(ref, :validation_failed, "The category is not valid.", %{
        "errors" => Common.changeset_errors(changeset)
      })
    end
  end

  defp external_id_taken(ref, holder_uuid) do
    Common.row_error(
      ref,
      :already_exists,
      "Another category of the catalogue already has this external_id.",
      %{
        "existing_id" => holder_uuid
      }
    )
  end

  defp holder_of(nil, _catalogue), do: nil

  defp holder_of(eid, catalogue) do
    case lookup(%{"external_id" => eid}, catalogue) do
      {:ok, category} -> category.uuid
      {:error, _reason} -> nil
    end
  end
end
