defmodule PhoenixKitCatalogue.Import.Executor do
  @moduledoc """
  Executes an import plan by creating categories and items.

  Categories are created first (get-or-create pattern), then items
  are inserted with progress reporting back to the calling process.
  """

  alias PhoenixKit.Utils.Multilang
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
    * `:match_categories_across_languages` — when `true`, the
      get-or-create lookup for column-mode category creation matches
      column values against every translation any existing category
      has, not just the current import language. Default `false`.
  """
  @spec execute(map(), String.t(), pid(), keyword()) :: import_result()
  def execute(import_plan, catalogue_uuid, notify_pid, opts \\ []) do
    language = Keyword.get(opts, :language)
    fixed_category_uuid = Keyword.get(opts, :category_uuid)
    match_across = Keyword.get(opts, :match_categories_across_languages, false)
    activity_opts = build_activity_opts(opts)

    # Phase 1: Create categories (only if no fixed category)
    {category_lookup, categories_created} =
      if fixed_category_uuid do
        {%{}, 0}
      else
        create_categories(
          import_plan.categories_to_create,
          catalogue_uuid,
          language,
          match_across,
          activity_opts
        )
      end

    # Phase 2: Create items
    total = length(import_plan.items)

    {created, errors} =
      import_plan.items
      |> Enum.with_index(1)
      |> Enum.reduce({0, []}, fn {item_attrs, idx}, {cr, errs} ->
        attrs =
          item_attrs
          |> Map.put(:catalogue_uuid, catalogue_uuid)
          |> resolve_category(category_lookup, fixed_category_uuid)
          |> apply_language(language)

        result = insert_item(attrs, activity_opts)

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

  defp create_categories(category_names, catalogue_uuid, language, match_across, activity_opts) do
    existing_categories = Catalogue.list_categories_for_catalogue(catalogue_uuid)
    existing = build_category_lookup(existing_categories, language, match_across)

    Enum.reduce(category_names, {existing, 0}, fn name, {lookup, count} ->
      if Map.has_key?(lookup, name) do
        {lookup, count}
      else
        get_or_create_category(name, catalogue_uuid, language, lookup, count, activity_opts)
      end
    end)
  end

  # Builds the `name => uuid` lookup the importer uses to match column
  # values to existing categories.
  #
  # Without a language we fall back to the bare `name` field — same as
  # the pre-multilang behavior, and the right thing for catalogues that
  # never enabled translations.
  #
  # With a language, we ALSO index each category by its translated
  # `_name` in that language, so importing a CSV with category column
  # values like "Konksud" matches a category whose `data.et._name` is
  # "Konksud" — even if its bare/primary name is "Hooks". The bare
  # `name` is also indexed as a fallback so categories without a
  # translation set in this language are still findable by their
  # primary name. On collisions the language-specific entry wins
  # because it's `Map.put`-ed last.
  #
  # When `match_across_languages` is true, we additionally index every
  # `_name` translation present on each category — so a column value
  # can match against a sibling-language translation even when
  # importing under a different language. Useful for consolidating
  # multilingual catalogues without forcing the user to re-import once
  # per language tab.
  defp build_category_lookup(categories, nil, _match_across) do
    Map.new(categories, fn cat -> {cat.name, cat.uuid} end)
  end

  defp build_category_lookup(categories, language, match_across) do
    Enum.reduce(categories, %{}, fn cat, acc ->
      acc
      |> Map.put(cat.name, cat.uuid)
      |> maybe_index_all_translations(cat, match_across)
      |> maybe_index_translation(cat, language)
    end)
  end

  defp maybe_index_all_translations(acc, _cat, false), do: acc

  defp maybe_index_all_translations(acc, %{data: data} = cat, true) when is_map(data) do
    Enum.reduce(data, acc, fn
      {key, %{"_name" => name}}, inner_acc
      when is_binary(name) and name != "" and key != "_primary_language" ->
        Map.put(inner_acc, name, cat.uuid)

      _, inner_acc ->
        inner_acc
    end)
  end

  defp maybe_index_all_translations(acc, _cat, true), do: acc

  defp maybe_index_translation(acc, cat, language) do
    case translated_name(cat, language) do
      nil -> acc
      translated -> Map.put(acc, translated, cat.uuid)
    end
  end

  defp translated_name(%{data: data}, language) when is_map(data) do
    case Multilang.get_language_data(data, language) do
      %{"_name" => name} when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  defp translated_name(_cat, _language), do: nil

  defp get_or_create_category(name, catalogue_uuid, language, lookup, count, activity_opts) do
    position = Catalogue.next_category_position(catalogue_uuid)

    # Apply the import language to the category the same way we do for
    # items — so the imported name lands in `data` under the chosen
    # language tab and `_primary_language` is set, instead of being a
    # bare string with no translation context.
    attrs =
      %{name: name, catalogue_uuid: catalogue_uuid, position: position}
      |> apply_language(language)

    case Catalogue.create_category(attrs, activity_opts) do
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

  # We pass `:skip_derive` because the executor already guarantees attrs
  # consistency: `catalogue_uuid` is the import target, and `category_uuid`
  # (if set) was either just created inside that catalogue or was picked
  # from a UI dropdown restricted to it. Skipping derivation avoids one DB
  # lookup per imported item.
  defp insert_item(attrs, activity_opts) do
    case Catalogue.create_item(attrs, [skip_derive: true] ++ activity_opts) do
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

  defp build_activity_opts(opts) do
    case Keyword.get(opts, :actor_uuid) do
      nil -> [mode: "auto"]
      uuid -> [actor_uuid: uuid, mode: "auto"]
    end
  end

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
