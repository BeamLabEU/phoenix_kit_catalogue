defmodule PhoenixKitCatalogue.API.UpdateProducts do
  @moduledoc false
  # Tool `catalogue.update_products` (spec 6.1). See the task text for the rules.

  alias PhoenixKitCatalogue.API
  alias PhoenixKitCatalogue.API.{Attributes, Common}
  alias PhoenixKitCatalogue.Catalogue

  @tool "catalogue.update_products"
  @columns %{
    "name" => :name,
    "description" => :description,
    "sku" => :sku,
    "status" => :status,
    "unit" => :unit
  }
  @external_id_path ["api", "external_id"]

  @spec call(map(), map()) ::
          {:ok, map()} | {:preview, map(), String.t()} | {:error, atom(), String.t(), map()}
  def call(input, ctx) do
    with :ok <- Common.ensure_schema(),
         {:ok, catalogue} <- API.resolve_catalogue(input["catalogue_id"], writable: true) do
      entries = input["items"]

      resolutions =
        API.resolve_refs(Enum.map(entries, & &1["ref"]),
          kind: :item,
          catalogue_uuid: catalogue.uuid
        )

      plan = plan(Enum.zip(entries, resolutions), catalogue)

      if ctx.dry_run?, do: preview(plan), else: execute(plan, catalogue, ctx)
    end
  end

  # --- planning (reads only) ---------------------------------------------------------

  # A planned row is `{:update, ref, item, update}`, `{:rejected, ref, message, context}`
  # or `{:resolution_error, ref, reason}`.
  defp plan(pairs, catalogue) do
    {planned, _state} =
      Enum.map_reduce(pairs, %{seen: MapSet.new(), categories: %{}}, fn {entry, {ref, resolution}},
                                                                        state ->
        plan_one(entry["changes"], ref, resolution, catalogue, state)
      end)

    planned
  end

  defp plan_one(_changes, ref, {:error, reason}, _catalogue, state),
    do: {{:resolution_error, ref, reason}, state}

  defp plan_one(changes, ref, {:ok, item}, catalogue, state) do
    cond do
      MapSet.member?(state.seen, item.uuid) ->
        {rejected(ref, "ref", "The same item appears twice in this request."), state}

      map_size(changes) == 0 ->
        {rejected(ref, "changes", "must name at least one field to change"), state}

      true ->
        case build(changes, catalogue, state) do
          {:ok, update, state} ->
            {{:update, ref, item, update}, %{state | seen: MapSet.put(state.seen, item.uuid)}}

          {:error, path, message, context} ->
            {rejected(ref, path, message, context), state}
        end
    end
  end

  defp rejected(ref, path, message, context \\ %{}) do
    {:rejected, ref, message,
     Map.merge(%{"errors" => [%{"path" => path, "message" => message}]}, context)}
  end

  defp build(changes, catalogue, state) do
    with :ok <- check_name(changes),
         :ok <- check_external_id(changes),
         {:ok, category, state} <- check_category(changes, catalogue, state),
         :ok <- check_attributes(changes) do
      {attrs, row_opts} = column_attrs(changes)

      update = %{
        attrs: attrs,
        # the category (if any) is moved separately (D12), so the update never derives it
        row_opts: [skip_derive: true] ++ row_opts,
        category: category,
        attributes: changes["attributes"] || [],
        external_id: changes["external_id"]
      }

      {:ok, update, state}
    end
  end

  defp check_name(%{"name" => name}) do
    if Common.blank?(name),
      do: {:error, "changes.name", "must not be blank", %{}},
      else: :ok
  end

  defp check_name(_changes), do: :ok

  defp check_external_id(%{"external_id" => eid}) when is_binary(eid) do
    if Common.blank?(eid),
      do: {:error, "changes.external_id", "must not be blank; send null to clear it", %{}},
      else: :ok
  end

  defp check_external_id(_changes), do: :ok

  # `:keep` = not mentioned, `nil` = uncategorize, a uuid = move there.
  defp check_category(changes, catalogue, state) do
    case Map.fetch(changes, "category_id") do
      :error ->
        {:ok, :keep, state}

      {:ok, nil} ->
        {:ok, nil, state}

      {:ok, id} ->
        {verdict, cache} = Common.category_verdict(id, catalogue, state.categories)
        state = %{state | categories: cache}

        case verdict do
          :ok -> {:ok, id, state}
          {:error, message} -> {:error, "changes.category_id", message, %{}}
        end
    end
  end

  defp check_attributes(changes) do
    case Attributes.validate(changes["attributes"] || []) do
      :ok -> :ok
      {:error, message, context} -> {:error, "changes.attributes", message, context}
    end
  end

  defp column_attrs(changes) do
    attrs =
      for {key, field} <- @columns,
          Map.has_key?(changes, key),
          into: %{},
          do: {field, column_value(field, changes[key])}

    if Map.has_key?(changes, "external_id") do
      attrs = Map.put(attrs, :data, %{"api" => %{"external_id" => changes["external_id"]}})
      {attrs, [data_owned_paths: [@external_id_path], logged_data_paths: [@external_id_path]]}
    else
      {attrs, []}
    end
  end

  # A blank name is refused at plan time, so the trim never empties it.
  defp column_value(:name, name), do: String.trim(name)
  defp column_value(_field, value), do: value

  # --- dry run -------------------------------------------------------------------------

  defp preview(plan) do
    plan
    |> Enum.map(fn
      {:update, ref, item, update} ->
        preview_row(ref, item, update)

      {:rejected, ref, message, context} ->
        Common.row_error(ref, :validation_failed, message, context)

      {:resolution_error, ref, reason} ->
        Common.resolution_error(ref, reason)
    end)
    |> Common.preview()
  end

  defp preview_row(ref, item, update) do
    case Catalogue.preview_item_update(item, update.attrs, update.row_opts) do
      {:ok, changes} ->
        changes =
          changes
          |> with_category_change(item, update.category)
          |> with_attribute_changes(item, update.attributes)

        action = if changes == %{}, do: "unchanged", else: "updated"
        Common.row_ok(ref, action, item.uuid, %{"changes" => changes})

      {:error, changeset} ->
        Common.row_error(ref, :validation_failed, "The change is not valid.", %{
          "errors" => Common.changeset_errors(changeset)
        })
    end
  end

  defp with_category_change(changes, _item, :keep), do: changes
  defp with_category_change(changes, %{category_uuid: same}, same), do: changes

  defp with_category_change(changes, item, category) do
    Map.put(changes, "category_id", %{"from" => item.category_uuid || "", "to" => category || ""})
  end

  defp with_attribute_changes(changes, item, entries) do
    Enum.reduce(entries, changes, fn %{"set_id" => set_id, "values" => values}, acc ->
      current = Attributes.selection(item.uuid, set_id)

      if Enum.sort(current) == Enum.sort(values),
        do: acc,
        else:
          Map.put(acc, "attributes." <> set_id, %{
            "from" => Enum.join(current, ","),
            "to" => Enum.join(values, ",")
          })
    end)
  end

  # --- execution -------------------------------------------------------------------------

  defp execute(plan, catalogue, ctx) do
    opts = Common.write_opts(ctx, @tool)

    rows =
      for {:update, _ref, item, update} <- plan, do: {item.uuid, update.attrs, update.row_opts}

    # `update_items/2` and the category moves all run with `broadcast: false`; the handler
    # announces ONCE, below, every item that changed in any way (columns, category, attributes).
    case Catalogue.update_items(rows, Keyword.put(opts, :broadcast, false)) do
      {:ok, outcomes} ->
        by_uuid = Map.new(outcomes)
        result_rows = Enum.map(plan, &finish(&1, by_uuid, opts, catalogue))

        changed =
          for %{"id" => id} = row <- result_rows,
              is_binary(id),
              row["action"] == "updated" or
                get_in(row, ["error", "context", "columns_saved"]) == true,
              do: id

        Catalogue.broadcast_item_batch_change(catalogue.uuid, :updated, changed)
        Common.batch_result(result_rows)

      {:error, reason} ->
        {:error, :internal_error, "The batch could not be written.", %{reason: inspect(reason)}}
    end
  end

  defp finish({:rejected, ref, message, context}, _outcomes, _opts, _catalogue),
    do: Common.row_error(ref, :validation_failed, message, context)

  defp finish({:resolution_error, ref, reason}, _outcomes, _opts, _catalogue),
    do: Common.resolution_error(ref, reason)

  defp finish({:update, ref, item, update}, outcomes, opts, catalogue) do
    case Map.get(outcomes, item.uuid) do
      {kind, updated} when kind in [:updated, :unchanged] ->
        follow_up(ref, kind, updated, update, opts)

      {:error, reason} ->
        failure(ref, reason, update, catalogue)

      nil ->
        Common.row_error(ref, :internal_error, "The item was not part of the write.")
    end
  end

  # After the columns: the category move, then the attribute selections.
  defp follow_up(ref, kind, updated, update, opts) do
    # Asked BEFORE the write: afterwards the selection always equals the request.
    attributes_changed? = Attributes.changed?(updated.uuid, update.attributes)

    with {:ok, moved?} <- move_category(updated, update.category, opts),
         :ok <- apply_attributes(updated, update.attributes, opts) do
      changed? = kind == :updated or moved? or attributes_changed?
      Common.row_ok(ref, if(changed?, do: "updated", else: "unchanged"), updated.uuid)
    else
      {:error, message} ->
        ref
        |> Common.row_error(:validation_failed, message, %{"columns_saved" => kind == :updated})
        |> Map.put("id", updated.uuid)
    end
  end

  defp move_category(_item, :keep, _opts), do: {:ok, false}
  defp move_category(%{category_uuid: same}, same, _opts), do: {:ok, false}

  defp move_category(item, category, opts) do
    # `broadcast: false`: the batch is announced once by `execute/3` (a move logs one
    # `item.moved` entry per item, the context's own action with readable from/to;
    # see D12 for why that is the one place the batch is not a single log insert).
    move_opts = Keyword.take(opts, [:actor_uuid, :mode, :log_metadata]) ++ [broadcast: false]

    case Catalogue.move_item_to_category(item, category, move_opts) do
      {:ok, _moved} ->
        {:ok, true}

      {:error, reason} ->
        {:error,
         "The item was updated but could not be moved to the category: #{inspect(reason)}."}
    end
  end

  defp apply_attributes(_item, [], _opts), do: :ok

  defp apply_attributes(item, entries, opts) do
    # `broadcast: false`: the batch is announced once by `execute/3`.
    attribute_opts = Keyword.take(opts, [:actor_uuid, :mode, :log_metadata]) ++ [broadcast: false]

    case Attributes.apply_to_item(item.uuid, entries, attribute_opts) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, "The item was updated but its attributes were not saved: #{inspect(reason)}."}
    end
  end

  defp failure(ref, %Ecto.Changeset{} = changeset, update, catalogue) do
    if Common.external_id_conflict?(changeset) do
      Common.row_error(
        ref,
        :already_exists,
        "Another item of the catalogue already has this external_id.",
        %{
          "existing_id" => holder_of(update.external_id, catalogue)
        }
      )
    else
      Common.row_error(ref, :validation_failed, "The change is not valid.", %{
        "errors" => Common.changeset_errors(changeset)
      })
    end
  end

  defp failure(ref, :not_found, _update, _catalogue),
    do: Common.row_error(ref, :not_found, "The item no longer exists.")

  defp failure(ref, _reason, _update, _catalogue),
    do: Common.row_error(ref, :internal_error, "The item could not be written.")

  defp holder_of(nil, _catalogue), do: nil

  defp holder_of(external_id, catalogue) do
    case API.resolve_refs([%{"external_id" => external_id}],
           kind: :item,
           catalogue_uuid: catalogue.uuid
         ) do
      [{_ref, {:ok, item}}] -> item.uuid
      _other -> nil
    end
  end
end
