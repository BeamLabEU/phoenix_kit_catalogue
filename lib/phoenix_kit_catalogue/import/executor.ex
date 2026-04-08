defmodule PhoenixKitCatalogue.Import.Executor do
  @moduledoc """
  Executes an import plan by creating categories and items.

  Categories are created first (get-or-create pattern), then items
  are inserted with progress reporting back to the calling process.
  """

  alias PhoenixKitCatalogue.Catalogue

  @type import_result :: %{
          created: non_neg_integer(),
          errors: [{non_neg_integer(), String.t()}],
          categories_created: non_neg_integer()
        }

  @doc """
  Executes an import plan.

  Creates categories first, then items. Sends `{:import_progress, current, total}`
  messages to `notify_pid` after each item.

  ## Options

    * `:language` — language code for multilang import (e.g. `"et"`)
    * `:category_uuid` — fixed category UUID to assign all items to
  """
  @spec execute(map(), String.t(), pid(), keyword()) :: import_result()
  def execute(import_plan, catalogue_uuid, notify_pid, opts \\ []) do
    language = Keyword.get(opts, :language)
    fixed_category_uuid = Keyword.get(opts, :category_uuid)

    # Phase 1: Create categories (only if no fixed category)
    {category_lookup, categories_created} =
      if fixed_category_uuid do
        {%{}, 0}
      else
        create_categories(import_plan.categories_to_create, catalogue_uuid)
      end

    # Phase 2: Create items
    total = length(import_plan.items)

    {created, errors} =
      import_plan.items
      |> Enum.with_index(1)
      |> Enum.reduce({0, []}, fn {item_attrs, idx}, {cr, errs} ->
        attrs =
          item_attrs
          |> resolve_category(category_lookup, fixed_category_uuid)
          |> apply_language(language)

        result = insert_item(attrs)

        send(notify_pid, {:import_progress, idx, total})

        case result do
          {:ok, :created} -> {cr + 1, errs}
          {:error, reason} -> {cr, [{idx, reason} | errs]}
        end
      end)

    result = %{
      created: created,
      errors: Enum.reverse(errors),
      categories_created: categories_created
    }

    send(notify_pid, {:import_result, result})

    result
  end

  # ── Category Creation ─────────────────────────────────────────

  defp create_categories(category_names, catalogue_uuid) do
    # Load existing categories for this catalogue
    existing =
      Catalogue.list_categories_for_catalogue(catalogue_uuid)
      |> Map.new(fn cat -> {cat.name, cat.uuid} end)

    Enum.reduce(category_names, {existing, 0}, fn name, {lookup, count} ->
      if Map.has_key?(lookup, name) do
        {lookup, count}
      else
        get_or_create_category(name, catalogue_uuid, lookup, count)
      end
    end)
  end

  defp get_or_create_category(name, catalogue_uuid, lookup, count) do
    position = Catalogue.next_category_position(catalogue_uuid)

    case Catalogue.create_category(%{
           name: name,
           catalogue_uuid: catalogue_uuid,
           position: position
         }) do
      {:ok, category} ->
        {Map.put(lookup, name, category.uuid), count + 1}

      {:error, _changeset} ->
        {lookup, count}
    end
  end

  # ── Language ───────────────────────────────────────────────────

  defp apply_language(attrs, nil), do: attrs

  defp apply_language(attrs, language) do
    translatable = %{}

    translatable =
      if attrs[:name], do: Map.put(translatable, "_name", attrs[:name]), else: translatable

    translatable =
      if attrs[:description],
        do: Map.put(translatable, "_description", attrs[:description]),
        else: translatable

    if map_size(translatable) > 0 do
      existing_data = attrs[:data] || %{}

      # Set the import language as the primary language for these items
      new_data = %{
        "_primary_language" => language,
        language => translatable
      }

      # Merge with any other data (like original_unit)
      new_data = Map.merge(new_data, Map.drop(existing_data, ["_primary_language"]))

      Map.put(attrs, :data, new_data)
    else
      attrs
    end
  end

  # ── Item Insertion ────────────────────────────────────────────

  defp insert_item(attrs) do
    case Catalogue.create_item(attrs) do
      {:ok, _item} ->
        {:ok, :created}

      {:error, changeset} ->
        {:error, format_changeset_errors(changeset)}
    end
  end

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join(", ", fn {field, msgs} ->
      "#{field}: #{Enum.join(msgs, ", ")}"
    end)
  end

  # ── Helpers ───────────────────────────────────────────────────

  defp resolve_category(attrs, _category_lookup, fixed_uuid) when is_binary(fixed_uuid) do
    attrs
    |> Map.delete(:_category_name)
    |> Map.put(:category_uuid, fixed_uuid)
  end

  defp resolve_category(attrs, category_lookup, _fixed_uuid) do
    case Map.pop(attrs, :_category_name) do
      {nil, attrs} ->
        attrs

      {"", attrs} ->
        attrs

      {name, attrs} ->
        case Map.get(category_lookup, name) do
          nil -> attrs
          uuid -> Map.put(attrs, :category_uuid, uuid)
        end
    end
  end
end
