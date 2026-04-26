defmodule PhoenixKitCatalogue.Import.Executor do
  @moduledoc """
  Executes an import plan by creating categories and items.

  Categories are created first (get-or-create pattern), then items
  are inserted with progress reporting back to the calling process.
  """

  require Logger

  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.PubSub

  @type import_result :: %{
          created: non_neg_integer(),
          errors: [{non_neg_integer(), String.t()}],
          categories_created: non_neg_integer(),
          manufacturers_created: non_neg_integer(),
          suppliers_created: non_neg_integer(),
          manufacturer_supplier_links_created: non_neg_integer()
        }

  @doc """
  Executes an import plan.

  Phase 1: get-or-create categories / manufacturers / suppliers
  (column mode only — fixed-uuid modes skip phase 1 for the
  corresponding entity). Phase 2: insert items, resolving
  `category_uuid` / `manufacturer_uuid` per row from the lookups
  built in phase 1 (or the fixed UUIDs). Phase 3: link
  manufacturers↔suppliers (M:N). Sends `{:import_progress, current,
  total}` messages to `notify_pid` after each item.

  ## Options

    * `:language` — language code for multilang import (e.g. `"et"`)
    * `:category_uuid` — fixed category UUID to assign all items to
    * `:match_categories_across_languages` — when `true`, the
      get-or-create lookup for column-mode category creation matches
      column values against every translation any existing category
      has, not just the current import language. Default `false`.
    * `:manufacturer_uuid` — fixed manufacturer UUID to assign all
      items to (skips phase 1 manufacturer creation)
    * `:supplier_uuid` — fixed supplier UUID; in phase 3 this supplier
      is linked (M:N) to every distinct manufacturer the items in
      this import ended up assigned to
  """
  @spec execute(map(), String.t(), pid(), keyword()) :: import_result()
  def execute(import_plan, catalogue_uuid, notify_pid, opts \\ []) do
    language = Keyword.get(opts, :language)
    fixed_category_uuid = Keyword.get(opts, :category_uuid)
    fixed_manufacturer_uuid = Keyword.get(opts, :manufacturer_uuid)
    fixed_supplier_uuid = Keyword.get(opts, :supplier_uuid)
    match_across = Keyword.get(opts, :match_categories_across_languages, false)
    activity_opts = build_activity_opts(opts)

    # Phase 1: get-or-create supporting records (skipped per-entity when
    # a fixed UUID is provided for it). Wrapped in a single transaction
    # so a raise in the second/third loop (DB drop, unexpected error in
    # Catalogue.create_*) rolls back any entities the earlier loops
    # already persisted — otherwise we'd leak orphan categories when
    # manufacturer creation crashed. Per-name changeset errors still get
    # logged + skipped (they return `{:error, _}`, not raises) which is
    # the existing contract; this wrapper only catches the abnormal
    # path. Cost on fixed-uuid-only imports: one empty txn roundtrip.
    #
    # `Map.get` defaults on the new keys guard against older callers /
    # hand-built plans that predate manufacturer + supplier support
    # (mirrors the forgiving contract `categories_to_create` already had
    # via the Mapper).
    {:ok,
     {{category_lookup, categories_created}, {manufacturer_lookup, manufacturers_created},
      {supplier_lookup, suppliers_created}}} =
      PhoenixKit.RepoHelper.repo().transaction(fn ->
        cats =
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

        mfrs =
          if fixed_manufacturer_uuid do
            {%{}, 0}
          else
            create_manufacturers(
              Map.get(import_plan, :manufacturers_to_create, []),
              activity_opts
            )
          end

        sups =
          if fixed_supplier_uuid do
            {%{}, 0}
          else
            create_suppliers(Map.get(import_plan, :suppliers_to_create, []), activity_opts)
          end

        {cats, mfrs, sups}
      end)

    # Phase 2: Create items, accumulating M:N link pairs along the way
    total = length(import_plan.items)
    initial_acc = {0, [], MapSet.new(), MapSet.new()}

    {created, errors, link_pairs, manufacturers_touched} =
      import_plan.items
      |> Enum.with_index(1)
      |> Enum.reduce(initial_acc, fn {item_attrs, idx}, {cr, errs, pairs, mfrs} ->
        {mfr_uuid, attrs} =
          item_attrs
          |> resolve_manufacturer(manufacturer_lookup, fixed_manufacturer_uuid)

        {sup_uuid, attrs} = resolve_supplier(attrs, supplier_lookup, fixed_supplier_uuid)

        attrs =
          attrs
          |> Map.put(:catalogue_uuid, catalogue_uuid)
          |> maybe_put(:manufacturer_uuid, mfr_uuid)
          |> resolve_category(category_lookup, fixed_category_uuid)
          |> apply_language(language)

        result = insert_item(attrs, activity_opts)

        send(notify_pid, {:import_progress, idx, total})

        accumulate_item_result(result, {cr, errs, pairs, mfrs}, idx, mfr_uuid, sup_uuid)
      end)

    # Phase 3: M:N links. A fixed supplier (existing/create mode) gets
    # linked to every manufacturer the import ended up touching;
    # otherwise we use the per-row pairs collected during phase 2.
    pairs_to_link = expand_supplier_links(link_pairs, manufacturers_touched, fixed_supplier_uuid)
    links_created = create_manufacturer_supplier_links(pairs_to_link)

    result = %{
      created: created,
      errors: Enum.reverse(errors),
      categories_created: categories_created,
      manufacturers_created: manufacturers_created,
      suppliers_created: suppliers_created,
      manufacturer_supplier_links_created: links_created
    }

    # Roll-up broadcast: per-row events were suppressed via
    # `broadcast: false` to keep open detail LVs responsive during the
    # import. One `:catalogue` event here lets every subscriber refresh
    # their slice once, after all rows have landed. We broadcast even on
    # zero-created imports so any in-progress UI ("Importing..." flash,
    # etc.) gets a definitive "done" signal.
    PubSub.broadcast(:catalogue, catalogue_uuid, catalogue_uuid)

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
  #
  # `broadcast: false` suppresses the per-row PubSub fan-out — a single
  # roll-up `:catalogue` event fires once at the end of `execute/4`. With
  # it on, a 1k-row import sent 1k broadcasts and any open detail LV would
  # spend the rest of the import re-running `refresh_in_place` on each one.
  defp insert_item(attrs, activity_opts) do
    case Catalogue.create_item(attrs, [skip_derive: true, broadcast: false] ++ activity_opts) do
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

  # ── Manufacturer creation + per-item resolution ───────────────

  defp create_manufacturers([], _activity_opts), do: {%{}, 0}

  defp create_manufacturers(names, activity_opts) do
    existing =
      Catalogue.list_manufacturers()
      |> Map.new(fn m -> {m.name, m.uuid} end)

    Enum.reduce(names, {existing, 0}, fn name, acc ->
      get_or_create_manufacturer(acc, name, activity_opts)
    end)
  end

  defp get_or_create_manufacturer({lookup, count}, name, _activity_opts)
       when is_map_key(lookup, name),
       do: {lookup, count}

  defp get_or_create_manufacturer({lookup, count}, name, activity_opts) do
    case Catalogue.create_manufacturer(%{name: name}, activity_opts) do
      {:ok, mfr} ->
        {Map.put(lookup, name, mfr.uuid), count + 1}

      {:error, changeset} ->
        # Items referencing this name will fall through with
        # `manufacturer_uuid: nil`; surface why so it's debuggable.
        Logger.warning(
          "Import: failed to create manufacturer #{inspect(name)}: " <>
            inspect(changeset.errors)
        )

        {lookup, count}
    end
  end

  # Returns `{manufacturer_uuid_or_nil, attrs_without_placeholder}`.
  # When a fixed UUID is supplied (existing/create UI mode) every item
  # gets it; otherwise we resolve from the column-mode lookup. A blank
  # or unmatched name leaves `manufacturer_uuid` unset on the item.
  defp resolve_manufacturer(attrs, _lookup, fixed_uuid) when is_binary(fixed_uuid) do
    {fixed_uuid, Map.delete(attrs, :_manufacturer_name)}
  end

  defp resolve_manufacturer(attrs, lookup, _fixed_uuid) do
    case Map.pop(attrs, :_manufacturer_name) do
      {nil, attrs} -> {nil, attrs}
      {"", attrs} -> {nil, attrs}
      {name, attrs} -> {Map.get(lookup, name), attrs}
    end
  end

  # ── Supplier creation + per-row resolution ────────────────────

  defp create_suppliers([], _activity_opts), do: {%{}, 0}

  defp create_suppliers(names, activity_opts) do
    existing =
      Catalogue.list_suppliers()
      |> Map.new(fn s -> {s.name, s.uuid} end)

    Enum.reduce(names, {existing, 0}, fn name, acc ->
      get_or_create_supplier(acc, name, activity_opts)
    end)
  end

  defp get_or_create_supplier({lookup, count}, name, _activity_opts)
       when is_map_key(lookup, name),
       do: {lookup, count}

  defp get_or_create_supplier({lookup, count}, name, activity_opts) do
    case Catalogue.create_supplier(%{name: name}, activity_opts) do
      {:ok, sup} ->
        {Map.put(lookup, name, sup.uuid), count + 1}

      {:error, changeset} ->
        Logger.warning(
          "Import: failed to create supplier #{inspect(name)}: " <>
            inspect(changeset.errors)
        )

        {lookup, count}
    end
  end

  # Returns `{supplier_uuid_or_nil, attrs_without_placeholder}`. Items
  # don't have a `supplier_uuid` column — the uuid travels alongside
  # the item attrs (not into them) and is used only for building the
  # M:N link in phase 3. We still strip the placeholder so it doesn't
  # leak into changeset cast.
  defp resolve_supplier(attrs, _lookup, fixed_uuid) when is_binary(fixed_uuid) do
    {fixed_uuid, Map.delete(attrs, :_supplier_name)}
  end

  defp resolve_supplier(attrs, lookup, _fixed_uuid) do
    case Map.pop(attrs, :_supplier_name) do
      {nil, attrs} -> {nil, attrs}
      {"", attrs} -> {nil, attrs}
      {name, attrs} -> {Map.get(lookup, name), attrs}
    end
  end

  # ── M:N link creation (phase 3) ───────────────────────────────

  # When the user picked a single supplier (existing / create mode),
  # link it to every manufacturer the import touched. Otherwise the
  # set of links comes purely from per-row pairs accumulated during
  # phase 2.
  defp expand_supplier_links(link_pairs, _manufacturers_touched, nil), do: link_pairs

  defp expand_supplier_links(link_pairs, manufacturers_touched, fixed_supplier_uuid) do
    Enum.reduce(manufacturers_touched, link_pairs, fn mfr_uuid, acc ->
      MapSet.put(acc, {mfr_uuid, fixed_supplier_uuid})
    end)
  end

  # Threads one item-insert outcome into the phase-2 accumulator: bumps
  # the success counter and records the (mfr, sup) pair / manufacturer
  # for phase-3 linking on `:ok`; appends to the error list on `:error`.
  defp accumulate_item_result({:ok, :created}, {cr, errs, pairs, mfrs}, _idx, mfr_uuid, sup_uuid) do
    new_pairs = maybe_record_pair(pairs, mfr_uuid, sup_uuid)
    new_mfrs = maybe_record_manufacturer(mfrs, mfr_uuid)
    {cr + 1, errs, new_pairs, new_mfrs}
  end

  defp accumulate_item_result({:error, reason}, {cr, errs, pairs, mfrs}, idx, _mfr, _sup) do
    {cr, [{idx, reason} | errs], pairs, mfrs}
  end

  defp maybe_record_pair(pairs, mfr_uuid, sup_uuid)
       when is_binary(mfr_uuid) and is_binary(sup_uuid),
       do: MapSet.put(pairs, {mfr_uuid, sup_uuid})

  defp maybe_record_pair(pairs, _, _), do: pairs

  defp maybe_record_manufacturer(mfrs, mfr_uuid) when is_binary(mfr_uuid),
    do: MapSet.put(mfrs, mfr_uuid)

  defp maybe_record_manufacturer(mfrs, _), do: mfrs

  # Skip the put when value is nil so we don't accidentally clobber
  # `manufacturer_uuid` to nil (e.g. via the Item changeset's cast
  # treating it as an explicit nil) when the row had no manufacturer.
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp create_manufacturer_supplier_links(pairs) do
    # `link_manufacturer_supplier/2` returns `{:error, changeset}` on
    # the unique-constraint violation when the link already exists —
    # that's the idempotency guarantee, so we treat it as a no-op.
    # Other errors (e.g., transient DB error) get logged so they're
    # debuggable; we still don't fail the whole import on a bad link
    # since items themselves are independent of the M:N graph.
    Enum.reduce(pairs, 0, fn pair, count -> attempt_link(pair, count) end)
  end

  defp attempt_link({mfr_uuid, sup_uuid}, count) do
    case Catalogue.link_manufacturer_supplier(mfr_uuid, sup_uuid) do
      {:ok, _} ->
        count + 1

      {:error, %Ecto.Changeset{errors: errors}} ->
        log_link_error(mfr_uuid, sup_uuid, errors)
        count
    end
  end

  defp log_link_error(mfr_uuid, sup_uuid, errors) do
    if unique_constraint_error?(errors) do
      :ok
    else
      Logger.warning(
        "Import: failed to link manufacturer #{mfr_uuid} ↔ supplier #{sup_uuid}: " <>
          inspect(errors)
      )
    end
  end

  defp unique_constraint_error?(errors) do
    Enum.any?(errors, fn {_, {_, opts}} -> opts[:constraint] == :unique end)
  end
end
