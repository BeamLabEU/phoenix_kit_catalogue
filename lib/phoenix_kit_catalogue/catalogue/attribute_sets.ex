defmodule PhoenixKitCatalogue.Catalogue.AttributeSets do
  @moduledoc """
  Attribute SETS — the 2026-08-18 rework of the group/attribute system.

  A set is one dimension from one vendor ("Ikea colors"), stored as a
  MANAGED entities blueprint (created only through this module, hidden
  from the generic entities admin); its data records are the values.
  Items attach any number of sets through the catalogue-owned
  `phoenix_kit_cat_item_attribute_sets` join (V176).

  ## The blueprint contract

      name:      "catalogue_set_<slug>"          (immutable identity)
      settings:  "managed_by"  => "catalogue"
                 "locked_keys" => ["kind", "default_value_slug"]
                 "catalogue"   => %{"kind" => "fixed" | "multi",
                                    "default_value_slug" => slug | nil}
      records:   slug = the value's stable key, title = display text,
                 position = order, data = extras (per-set fields)

  Everything else on the blueprint (display name, translations,
  `fields_definition` extras like "price per liter") is freely editable.
  `contract/1` validates the shape on every resolve; a broken contract
  is surfaced (`{:error, :contract_broken}`), never guessed around.

  ## Enablement

  Requires the entities module (`PhoenixKitEntities.enabled?/0`). Every
  public function returns `{:error, :entities_disabled}` when it is off
  — same loud-failure doctrine as the `:catalogue_pdf` queue guard.

  Public surface re-exported from `PhoenixKitCatalogue.Catalogue`.
  """

  import Ecto.Query
  require Logger

  alias PhoenixKitCatalogue.Catalogue.ActivityLog
  alias PhoenixKitCatalogue.Schemas.ItemAttributeSet

  @owner "catalogue"
  @slug_prefix "catalogue_set_"
  @locked_keys ["kind", "default_value_slug"]
  @kinds ~w(fixed multi)

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc """
  True when the sets feature is live: the entities module is enabled
  AND its package carries the Managed API (entities > 0.4.0) — on an
  older package the whole feature degrades to `:entities_disabled`
  rather than crashing on missing functions. UI surfaces branch on
  this to decide sets-vs-legacy rendering.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Code.ensure_loaded?(PhoenixKitEntities) and
      Code.ensure_loaded?(PhoenixKitEntities.Managed) and
      PhoenixKitEntities.enabled?()
  end

  defp entities_enabled?, do: enabled?()

  # ── Startup registration ───────────────────────────────────────────

  @doc """
  Registers the catalogue's blueprint delete guard with entities.
  Ships as a supervision child via `PhoenixKitCatalogue.children/0`, so
  it runs once per boot; deleting a set with item attachments is
  refused at the entities write path.
  """
  def child_spec(_opts) do
    %{
      id: __MODULE__.GuardRegistration,
      start: {Task, :start_link, [&__MODULE__.startup/0]},
      restart: :temporary
    }
  end

  @doc false
  def startup do
    register_deletion_guard()
    auto_migrate_legacy()
  end

  @doc """
  Migrates any remaining legacy groups into sets, silently and safely —
  there is no legacy UI once sets are live ("it should just migrate",
  boss direction 2026-08-18), so this runs from the supervision-tree
  startup task and again from the attributes page as a backstop (boot
  can race the repo/settings, and entities can be enabled at runtime).

  Never raises: any failure is logged and swallowed — a broken
  migration must not take down boot or an admin page. Idempotent by
  way of `migrate_groups_to_sets/1`.
  """
  @spec auto_migrate_legacy() :: :ok
  def auto_migrate_legacy do
    if enabled?() and PhoenixKitCatalogue.Catalogue.list_attribute_groups() != [] do
      case migrate_groups_to_sets() do
        {:ok, %{sets: 0, values: 0, attachments: 0}} ->
          :ok

        {:ok, counts} ->
          Logger.info("AttributeSets: auto-migrated legacy groups — #{inspect(counts)}")

        {:error, reason} ->
          Logger.warning("AttributeSets: legacy auto-migration failed: #{inspect(reason)}")
      end
    end

    :ok
  rescue
    error ->
      Logger.warning("AttributeSets: legacy auto-migration crashed: #{inspect(error)}")
      :ok
  catch
    :exit, reason ->
      Logger.warning("AttributeSets: legacy auto-migration exited: #{inspect(reason)}")
      :ok
  end

  @doc false
  def register_deletion_guard do
    if Code.ensure_loaded?(PhoenixKitEntities.Managed) do
      # EXTERNAL capture, never `&deletion_guard/1`: a local fun pins the
      # module version that registered it, and after a second code purge
      # (dev reloads, hot upgrades) calling it from :persistent_term is a
      # badfun crash. The external capture dispatches to the current
      # module version at call time (panel finding, 2026-08-18 review).
      PhoenixKitEntities.Managed.register_delete_guard(@owner, &__MODULE__.deletion_guard/1)
    end

    :ok
  end

  @doc false
  def deletion_guard(entity) do
    if set_attached?(entity.uuid), do: {:error, :set_in_use}, else: :ok
  end

  # ── Set CRUD (provisioned blueprints) ──────────────────────────────

  @doc """
  Provisions a new set: a managed blueprint from the locked template.

  `attrs`: `:name` (display, required), `:slug` (optional — derived
  from the name when absent), `:kind` (`"fixed"`/`"multi"`, default
  `"multi"`), `:description`.
  """
  @spec create_set(map(), keyword()) :: {:ok, struct()} | {:error, term()}
  def create_set(attrs, opts \\ []) do
    with :ok <- ensure_enabled(),
         {:ok, kind} <- validate_kind(Map.get(attrs, :kind, "multi")) do
      display = String.trim(Map.get(attrs, :name, ""))
      slug = @slug_prefix <> (Map.get(attrs, :slug) || slugify_name(display))

      %{
        name: slug,
        display_name: display,
        display_name_plural: display,
        description: Map.get(attrs, :description),
        status: "published",
        fields_definition: [],
        settings: %{
          "managed_by" => @owner,
          "locked_keys" => @locked_keys,
          "sort_mode" => "manual",
          "catalogue" => %{"kind" => kind, "default_value_slug" => nil}
        }
      }
      |> maybe_put_creator(opts)
      |> PhoenixKitEntities.create_entity(on_behalf_of: @owner)
      |> tap_log("attribute_set.created", opts, fn set ->
        %{"name" => set.display_name, "slug" => set.name, "kind" => kind}
      end)
    end
  end

  @doc "Lists the catalogue's sets (managed blueprints), locale-resolved."
  @spec list_sets(keyword()) :: [struct()]
  def list_sets(opts \\ []) do
    if entities_enabled?() do
      PhoenixKitEntities.list_entities(lang: opts[:lang])
      |> Enum.filter(&(PhoenixKitEntities.Managed.owner(&1) == @owner))
    else
      []
    end
  end

  @doc "Fetches one set by blueprint uuid (nil when missing/not a set)."
  @spec get_set(Ecto.UUID.t(), keyword()) :: struct() | nil
  def get_set(uuid, opts \\ []) do
    with true <- entities_enabled?(),
         %{} = entity <- PhoenixKitEntities.get_entity(uuid, lang: opts[:lang]),
         @owner <- PhoenixKitEntities.Managed.owner(entity) do
      entity
    else
      _ -> nil
    end
  end

  @doc """
  Updates a set's unlocked surface: `:name` (display), `:description`,
  `:kind`, `:default_value_slug`. Kind/default ride the owner bypass —
  they are locked against GENERIC writes, not against this module.
  """
  @spec update_set(struct(), map(), keyword()) :: {:ok, struct()} | {:error, term()}
  def update_set(set, attrs, opts \\ []) do
    with :ok <- ensure_enabled(),
         {:ok, kind} <- validate_kind(Map.get(attrs, :kind, current_kind(set))) do
      catalogue_settings =
        (set.settings["catalogue"] || %{})
        |> Map.put("kind", kind)
        |> Map.put(
          "default_value_slug",
          Map.get(attrs, :default_value_slug, current_default(set))
        )

      entity_attrs =
        %{settings: Map.put(set.settings, "catalogue", catalogue_settings)}
        |> maybe_put(:display_name, Map.get(attrs, :name))
        |> maybe_put(:display_name_plural, Map.get(attrs, :name))
        |> maybe_put(:description, Map.get(attrs, :description))

      set
      |> PhoenixKitEntities.update_entity(entity_attrs, on_behalf_of: @owner)
      |> tap_log("attribute_set.updated", opts, fn s -> %{"name" => s.display_name} end)
    end
  end

  @doc """
  Deletes a set. Refused (`{:error, :set_in_use}`) while any item
  attaches it — the same guard entities consults on its own delete path.
  """
  @spec delete_set(struct(), keyword()) :: {:ok, struct()} | {:error, term()}
  def delete_set(set, opts \\ []) do
    with :ok <- ensure_enabled() do
      # The attachment check runs here AND via the registered
      # entities-side guard (belt and suspenders), both under the same
      # per-set advisory lock `attach_set/3` takes — closing the
      # check-then-delete window a concurrent attach could slip through.
      repo().transaction(fn -> locked_delete(set) end)
      |> tap_log("attribute_set.deleted", opts, fn s ->
        %{"name" => s.display_name, "slug" => s.name}
      end)
    end
  end

  defp locked_delete(set) do
    lock_set(set.uuid)

    with :ok <- ensure_not_attached(set.uuid),
         {:ok, deleted} <- PhoenixKitEntities.delete_entity(set, on_behalf_of: @owner) do
      deleted
    else
      {:error, reason} -> repo().rollback(reason)
    end
  end

  defp ensure_not_attached(set_uuid) do
    if set_attached?(set_uuid), do: {:error, :set_in_use}, else: :ok
  end

  # ── Values (entity data records) ───────────────────────────────────

  @doc """
  Adds a value to a set. `attrs`: `:label` (required), `:slug`
  (derived from label when absent), `:extras` (map merged into the
  record's data — must match the blueprint's fields).
  """
  @spec create_value(struct(), map(), keyword()) :: {:ok, struct()} | {:error, term()}
  def create_value(set, attrs, opts \\ []) do
    with :ok <- ensure_enabled() do
      label = String.trim(Map.get(attrs, :label, ""))

      %{
        entity_uuid: set.uuid,
        title: label,
        slug: Map.get(attrs, :slug) || slugify_value(label),
        status: "published",
        data: Map.get(attrs, :extras, %{})
      }
      |> maybe_put_creator(opts)
      |> PhoenixKitEntities.EntityData.create()
      |> tap_log("attribute_set.value_created", opts, fn v ->
        %{"set" => set.name, "value" => v.slug}
      end)
    end
  end

  @doc "Lists a set's values in display order, locale-resolved."
  @spec list_values(struct() | Ecto.UUID.t(), keyword()) :: [struct()]
  def list_values(set_or_uuid, opts \\ [])
  def list_values(%{uuid: uuid}, opts), do: list_values(uuid, opts)

  def list_values(set_uuid, opts) when is_binary(set_uuid) do
    if entities_enabled?() do
      PhoenixKitEntities.EntityData.list_by_entity(set_uuid, lang: opts[:lang])
      |> Enum.reject(&(&1.status == "archived"))
    else
      []
    end
  end

  @doc "Fetches one value record, scoped to the set (nil when foreign/missing)."
  @spec get_value(struct(), Ecto.UUID.t()) :: struct() | nil
  def get_value(set, value_uuid) when is_binary(value_uuid) do
    with true <- entities_enabled?(),
         %{entity_uuid: entity_uuid} = record <- PhoenixKitEntities.EntityData.get(value_uuid),
         true <- entity_uuid == set.uuid do
      record
    else
      _ -> nil
    end
  end

  def get_value(_set, _), do: nil

  @doc """
  Updates a value: `:label` rewrites the display text (the slug — the
  stable key — never changes), `:extras` merges into the record data.

  Extras are cast per field type through the entities pipeline
  (`FormBuilder.cast_field/2`): raw form strings coerce ("12.5" →
  12.5, "" clears), invalid content returns `{:error, :invalid_value}`
  and unknown keys `{:error, :unknown_field}` — never a silent junk
  write.
  """
  @spec update_value(struct(), struct(), map(), keyword()) :: {:ok, struct()} | {:error, term()}
  def update_value(set, value, attrs, opts \\ []) do
    with :ok <- ensure_enabled(),
         {:ok, extras} <- cast_extras(set, Map.get(attrs, :extras)) do
      entity_attrs =
        %{}
        |> maybe_put(:title, Map.get(attrs, :label))
        |> maybe_put_extras(value, extras)

      value
      |> PhoenixKitEntities.EntityData.update(entity_attrs, activity_log: false)
      |> tap_log("attribute_set.value_updated", opts, fn v ->
        %{"set" => set.name, "value" => v.slug}
      end)
    end
  end

  defp cast_extras(_set, nil), do: {:ok, nil}

  defp cast_extras(set, extras) when is_map(extras) do
    fields = Map.new(set.fields_definition || [], &{&1["key"], &1})

    Enum.reduce_while(extras, {:ok, %{}}, fn {key, raw}, {:ok, acc} ->
      case cast_one_extra(fields[key], raw) do
        {:ok, cast} -> {:cont, {:ok, Map.put(acc, key, cast)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp cast_one_extra(nil, _raw), do: {:error, :unknown_field}

  defp cast_one_extra(field, raw) do
    case PhoenixKitEntities.FormBuilder.cast_field(field, raw) do
      {:ok, cast} -> {:ok, cast}
      {:error, _msgs} -> {:error, :invalid_value}
    end
  end

  @doc """
  Deletes a value record. When the value is the set's default, the
  default is cleared first so the contract never points at a ghost.
  """
  @spec delete_value(struct(), struct(), keyword()) :: {:ok, struct()} | {:error, term()}
  def delete_value(set, value, opts \\ []) do
    with :ok <- ensure_enabled(),
         :ok <- maybe_clear_default(set, value, opts) do
      value
      |> PhoenixKitEntities.EntityData.delete(activity_log: false)
      |> tap_log("attribute_set.value_deleted", opts, fn v ->
        %{"set" => set.name, "value" => v.slug}
      end)
    end
  end

  defp maybe_clear_default(set, value, opts) do
    if current_default(set) == value.slug do
      case update_set(set, %{default_value_slug: nil}, opts) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  @doc "Reorders a set's values to the given record-uuid order."
  @spec reorder_values(struct(), [Ecto.UUID.t()], keyword()) :: :ok | {:error, term()}
  def reorder_values(set, ordered_uuids, _opts \\ []) when is_list(ordered_uuids) do
    with :ok <- ensure_enabled() do
      PhoenixKitEntities.EntityData.reorder(set.uuid, ordered_uuids, activity_log: false)
      :ok
    end
  end

  # ── Extras (blueprint fields — "price per liter" etc.) ─────────────

  @extra_field_types ~w(text textarea number boolean date select image video)

  @doc "Extra-field types the set editor offers (a curated entities subset)."
  @spec extra_field_types() :: [String.t()]
  def extra_field_types, do: @extra_field_types

  @doc """
  Adds an extra field to the set's blueprint (`:label` required,
  `:type` one of `extra_field_types/0`; `select` additionally needs
  `:options`, a non-empty list). Every value can then carry data for
  it. The key is derived from the label and is stable.
  """
  @spec add_extra_field(struct(), map(), keyword()) :: {:ok, struct()} | {:error, term()}
  def add_extra_field(set, attrs, opts \\ []) do
    label = String.trim(Map.get(attrs, :label, ""))
    type = Map.get(attrs, :type, "text")

    options =
      attrs |> Map.get(:options, []) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    key = slugify_name(label)
    # Re-read before append: the caller's struct may be stale, and a
    # read-modify-write off it would silently drop a field another
    # session added meanwhile.
    set = get_set(set.uuid) || set
    fields = set.fields_definition || []

    with :ok <- ensure_enabled(),
         :ok <- validate_extra_field(label, type, key, options, fields) do
      definition = build_field_definition(type, key, label, options)

      set
      |> PhoenixKitEntities.update_entity(
        %{fields_definition: fields ++ [definition]},
        on_behalf_of: @owner
      )
      |> tap_log("attribute_set.field_added", opts, fn s ->
        %{"set" => s.name, "field" => key, "type" => type}
      end)
    end
  end

  defp build_field_definition("select", key, label, options),
    do: %{"type" => "select", "key" => key, "label" => label, "options" => options}

  defp build_field_definition(type, key, label, _options),
    do: %{"type" => type, "key" => key, "label" => label}

  defp validate_extra_field(label, type, key, options, fields) do
    cond do
      label == "" -> {:error, :label_required}
      type not in @extra_field_types -> {:error, :invalid_type}
      type == "select" and options == [] -> {:error, :options_required}
      Enum.any?(fields, &(&1["key"] == key)) -> {:error, :duplicate_key}
      true -> :ok
    end
  end

  @doc """
  Updates an existing extra field: `:label` renames the display text
  (the key — referenced by stored per-value data — never changes),
  `:options` replaces a select field's option list (non-empty
  required). The type is immutable after creation: stored values were
  cast for it.
  """
  @spec update_extra_field(struct(), String.t(), map(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def update_extra_field(set, key, attrs, opts \\ []) when is_binary(key) do
    set = get_set(set.uuid) || set
    fields = set.fields_definition || []

    with :ok <- ensure_enabled(),
         %{} = field <- Enum.find(fields, &(&1["key"] == key)) || {:error, :unknown_field},
         {:ok, updated_field} <- apply_field_update(field, attrs) do
      updated = Enum.map(fields, &if(&1["key"] == key, do: updated_field, else: &1))

      set
      |> PhoenixKitEntities.update_entity(%{fields_definition: updated}, on_behalf_of: @owner)
      |> tap_log("attribute_set.field_updated", opts, fn s ->
        %{"set" => s.name, "field" => key}
      end)
    end
  end

  defp apply_field_update(field, attrs) do
    label = attrs |> Map.get(:label, field["label"]) |> String.trim()

    options =
      case Map.get(attrs, :options) do
        nil -> field["options"]
        list -> list |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
      end

    cond do
      label == "" -> {:error, :label_required}
      field["type"] == "select" and options == [] -> {:error, :options_required}
      true -> {:ok, field |> Map.put("label", label) |> maybe_put_options(options)}
    end
  end

  defp maybe_put_options(field, nil), do: field

  defp maybe_put_options(%{"type" => "select"} = field, options),
    do: Map.put(field, "options", options)

  defp maybe_put_options(field, _options), do: field

  @doc """
  Removes an extra field from the blueprint. Existing per-value data
  for the key is left in place (harmless, invisible) — same doctrine
  as entities' own field removal.
  """
  @spec remove_extra_field(struct(), String.t(), keyword()) :: {:ok, struct()} | {:error, term()}
  def remove_extra_field(set, key, opts \\ []) when is_binary(key) do
    with :ok <- ensure_enabled() do
      fields = Enum.reject(set.fields_definition || [], &(&1["key"] == key))

      set
      |> PhoenixKitEntities.update_entity(%{fields_definition: fields}, on_behalf_of: @owner)
      |> tap_log("attribute_set.field_removed", opts, fn s ->
        %{"set" => s.name, "field" => key}
      end)
    end
  end

  # ── Contract ───────────────────────────────────────────────────────

  @doc """
  Validates a set blueprint's catalogue contract. Returns
  `{:ok, %{kind: atom, default: slug | nil}}` or
  `{:error, :contract_broken}` — never a guessed fallback.
  """
  @spec contract(struct()) :: {:ok, map()} | {:error, :contract_broken}
  def contract(%{settings: settings, name: @slug_prefix <> _} = _set) when is_map(settings) do
    catalogue = settings["catalogue"]

    case catalogue do
      %{"kind" => kind} when kind in @kinds ->
        {:ok, %{kind: String.to_existing_atom(kind), default: catalogue["default_value_slug"]}}

      _ ->
        {:error, :contract_broken}
    end
  end

  def contract(_), do: {:error, :contract_broken}

  # ── Attachments ────────────────────────────────────────────────────

  @doc """
  Attaches a set to an item (appends; no-op when already attached).

  Runs under the per-set advisory lock shared with `delete_set/2` —
  without it, an attach racing a delete could commit after the guard's
  `set_attached?` check read false, leaving an instant orphan row
  (panel finding, 2026-08-18 review).
  """
  @spec attach_set(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, ItemAttributeSet.t()} | {:error, term()}
  def attach_set(item_uuid, set_uuid, opts \\ []) do
    with :ok <- ensure_enabled() do
      repo().transaction(fn -> locked_attach(item_uuid, set_uuid) end)
      |> tap_log("attribute_set.attached", opts, fn _ ->
        %{"item_uuid" => item_uuid, "set_uuid" => set_uuid}
      end)
    end
  end

  defp locked_attach(item_uuid, set_uuid) do
    lock_set(set_uuid)

    with %{} <- get_set(set_uuid) || {:error, :set_not_found},
         {:ok, row} <- insert_attachment(item_uuid, set_uuid) do
      row
    else
      {:error, reason} -> repo().rollback(reason)
    end
  end

  defp insert_attachment(item_uuid, set_uuid) do
    position =
      repo().one(
        from(a in ItemAttributeSet,
          where: a.item_uuid == ^item_uuid,
          select: coalesce(max(a.position), 0)
        )
      ) + 1

    %ItemAttributeSet{}
    |> ItemAttributeSet.changeset(%{
      item_uuid: item_uuid,
      set_uuid: set_uuid,
      position: position
    })
    |> repo().insert(
      on_conflict: :nothing,
      conflict_target: [:item_uuid, :set_uuid]
    )
  end

  # Per-set advisory transaction lock serializing attach vs delete.
  # hashtextextended folds the uuid to a bigint; xact locks release on
  # commit/rollback, so there is nothing to clean up.
  defp lock_set(set_uuid) do
    repo().query!("SELECT pg_advisory_xact_lock(hashtextextended($1::text, 42))", [set_uuid])
  end

  @doc "Detaches a set from an item (no-op when not attached)."
  @spec detach_set(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) :: :ok
  def detach_set(item_uuid, set_uuid, opts \\ []) do
    {count, _} =
      repo().delete_all(
        from(a in ItemAttributeSet,
          where: a.item_uuid == ^item_uuid and a.set_uuid == ^set_uuid
        )
      )

    if count > 0 do
      log_activity("attribute_set.detached", opts, %{
        "item_uuid" => item_uuid,
        "set_uuid" => set_uuid
      })
    end

    :ok
  end

  @doc "Reorders an item's attachments to the given set_uuid order."
  @spec reorder_attachments(Ecto.UUID.t(), [Ecto.UUID.t()], keyword()) :: :ok
  def reorder_attachments(item_uuid, set_uuids, _opts \\ []) when is_list(set_uuids) do
    set_uuids
    |> Enum.uniq()
    |> Enum.with_index(1)
    |> Enum.each(fn {set_uuid, idx} ->
      from(a in ItemAttributeSet,
        where: a.item_uuid == ^item_uuid and a.set_uuid == ^set_uuid
      )
      |> repo().update_all(set: [position: idx])
    end)

    :ok
  end

  @doc "The item's attachments in order."
  @spec list_attachments(Ecto.UUID.t()) :: [ItemAttributeSet.t()]
  def list_attachments(item_uuid) do
    repo().all(
      from(a in ItemAttributeSet,
        where: a.item_uuid == ^item_uuid,
        order_by: [asc: a.position, asc: a.set_uuid]
      )
    )
  end

  @doc "True when any item attaches the set (drives the delete guard)."
  @spec set_attached?(Ecto.UUID.t()) :: boolean()
  def set_attached?(set_uuid) do
    repo().exists?(from(a in ItemAttributeSet, where: a.set_uuid == ^set_uuid))
  end

  @doc "How many items attach each of the given sets: %{set_uuid => count}."
  @spec attachment_counts([Ecto.UUID.t()]) :: %{optional(Ecto.UUID.t()) => non_neg_integer()}
  def attachment_counts([]), do: %{}

  def attachment_counts(set_uuids) when is_list(set_uuids) do
    repo().all(
      from(a in ItemAttributeSet,
        where: a.set_uuid in ^set_uuids,
        group_by: a.set_uuid,
        select: {a.set_uuid, count(a.item_uuid)}
      )
    )
    |> Map.new()
  end

  @doc """
  Removes attachments whose set blueprint no longer exists (called by
  `AttributeSets.OrphanPruner` off entities PubSub delete events).

  Guarded on enablement: with entities disabled, `get_set/1` returns
  nil for EVERY uuid — without the guard a stray call during a feature
  toggle would read that as "blueprint deleted" and destroy valid
  attachments (panel finding, 2026-08-18 review).
  """
  @spec prune_orphan_attachments(Ecto.UUID.t()) :: non_neg_integer()
  def prune_orphan_attachments(set_uuid) do
    cond do
      not entities_enabled?() ->
        0

      get_set(set_uuid) ->
        0

      true ->
        {count, _} =
          repo().delete_all(from(a in ItemAttributeSet, where: a.set_uuid == ^set_uuid))

        count
    end
  end

  # ── Resolution (the v2 consumer read) ──────────────────────────────

  @doc """
  Resolves the attached sets for many items in one batched pass:
  one attachment query + one value listing per DISTINCT set (values are
  shared across items, so a 50-item page with 6 sets is 7 queries).

  Returns `%{item_uuid => resolved}` where resolved is the v2 shape:

      %{schema_version: 2,
        sets: [%{uuid, key, name, kind, default,
                 values: [%{key, label, extras}]}]}

  Sets with a broken contract are skipped with a warning — a tampered
  blueprint must not take item pages down, but it must not render
  guessed data either.
  """
  @spec resolve_for_items([Ecto.UUID.t()], keyword()) :: %{optional(Ecto.UUID.t()) => map()}
  def resolve_for_items(item_uuids, opts \\ [])
  def resolve_for_items([], _opts), do: %{}

  def resolve_for_items(item_uuids, opts) when is_list(item_uuids) do
    if entities_enabled?() do
      attachments =
        repo().all(
          from(a in ItemAttributeSet,
            where: a.item_uuid in ^item_uuids,
            order_by: [asc: a.position, asc: a.set_uuid]
          )
        )

      resolved_sets =
        attachments
        |> Enum.map(& &1.set_uuid)
        |> Enum.uniq()
        |> Map.new(fn set_uuid -> {set_uuid, resolve_set(set_uuid, opts)} end)

      attachments
      |> Enum.group_by(& &1.item_uuid)
      |> Map.new(fn {item_uuid, rows} ->
        sets =
          rows
          |> Enum.map(&attach_selection(resolved_sets[&1.set_uuid], &1))
          |> Enum.reject(&is_nil/1)

        {item_uuid, %{schema_version: 2, sets: sets}}
      end)
    else
      %{}
    end
  end

  defp attach_selection(nil, _row), do: nil
  defp attach_selection(set, row), do: Map.put(set, :selected, selected_slugs(row))

  # The per-ATTACHMENT selection (boss's two modes, 2026-08-19): one
  # slug = "this exact object is Red", several = "this object comes in
  # Red/Blue/Yellow", empty = no statement, the whole set applies. The
  # count IS the mode — nothing else is tracked.
  defp selected_slugs(%ItemAttributeSet{data: data}) do
    case data["selected_value_slugs"] do
      slugs when is_list(slugs) -> Enum.filter(slugs, &is_binary/1)
      _ -> []
    end
  end

  @doc "Single-item convenience over `resolve_for_items/2`."
  @spec resolve_for_item(Ecto.UUID.t(), keyword()) :: map()
  def resolve_for_item(item_uuid, opts \\ []) do
    resolve_for_items([item_uuid], opts)
    |> Map.get(item_uuid, %{schema_version: 2, sets: []})
  end

  @doc """
  Resolves ONE set to the v2 per-set shape
  (`%{uuid, key, name, kind, default, values}`), or `nil` when the set
  is missing or its contract is broken. Powers the item form's
  attach-preview; the batched item reads go through
  `resolve_for_items/2`.
  """
  @spec resolve_set(Ecto.UUID.t(), keyword()) :: map() | nil
  def resolve_set(set_uuid, opts \\ []) do
    with %{} = set <- get_set(set_uuid, opts),
         {:ok, %{kind: kind, default: default}} <- contract(set) do
      values =
        set_uuid
        |> list_values(opts)
        |> Enum.map(fn record ->
          %{key: record.slug, label: record.title, extras: record.data || %{}}
        end)

      fields =
        Enum.map(set.fields_definition || [], fn f ->
          %{key: f["key"], label: f["label"], type: f["type"]}
        end)

      %{
        uuid: set_uuid,
        key: set.name,
        name: set.display_name,
        kind: kind,
        default: default,
        values: values,
        fields: fields
      }
    else
      nil ->
        nil

      {:error, :contract_broken} ->
        Logger.warning("AttributeSets: contract broken for set #{inspect(set_uuid)} — skipped")
        nil
    end
  end

  @doc """
  Stores the per-attachment value selection (`selected_value_slugs` in
  the join row's reserved `data`) — the boss's two modes: ONE slug says
  "this exact object is Red", several say "this object comes in these
  options", empty clears the statement. Unknown slugs are dropped
  against the set's current values; `{:error, :not_attached}` when the
  item doesn't attach the set.
  """
  @spec set_attachment_selection(Ecto.UUID.t(), Ecto.UUID.t(), [String.t()], keyword()) ::
          :ok | {:error, term()}
  def set_attachment_selection(item_uuid, set_uuid, slugs, opts \\ []) when is_list(slugs) do
    with :ok <- ensure_enabled(),
         %ItemAttributeSet{} = row <-
           repo().one(
             from(a in ItemAttributeSet,
               where: a.item_uuid == ^item_uuid and a.set_uuid == ^set_uuid
             )
           ) || {:error, :not_attached} do
      valid_keys =
        case resolve_set(set_uuid) do
          %{values: values} -> MapSet.new(values, & &1.key)
          nil -> MapSet.new()
        end

      selection = slugs |> Enum.filter(&(is_binary(&1) and &1 in valid_keys)) |> Enum.uniq()

      {:ok, _} =
        row
        |> ItemAttributeSet.changeset(%{
          data: Map.put(row.data || %{}, "selected_value_slugs", selection)
        })
        |> repo().update()

      log_activity("attribute_set.selection_changed", opts, %{
        "item_uuid" => item_uuid,
        "set_uuid" => set_uuid,
        "selected" => selection
      })

      :ok
    end
  end

  # ── Migration from the group system (dual-run; design doc §Migration) ─

  @doc """
  Migrates the legacy group→attribute→value data into sets:

    * each `(group, attribute)` pair → one set blueprint, slug
      `catalogue_set_<group>_<attr-key>` (display "<Group> — <Attr>");
    * attribute values → records, slug = the old value key (stable, so
      existing order-line picks keep resolving), old `is_default` → the
      set's `default_value_slug`;
    * every item's single group assignment explodes into one attachment
      per attribute of that group, in attribute order.

  Idempotent: an existing blueprint with the target slug is reused (its
  values/attachments are topped up, never duplicated), so re-running
  after a partial failure is safe. Old tables are left untouched
  (read-only by convention; dropped by a later core migration after
  cutover). Returns `{:ok, %{sets: n, values: n, attachments: n}}`.
  """
  @spec migrate_groups_to_sets(keyword()) :: {:ok, map()} | {:error, term()}
  def migrate_groups_to_sets(opts \\ []) do
    with :ok <- ensure_enabled() do
      groups = PhoenixKitCatalogue.Catalogue.list_attribute_groups()

      {set_map, counts} =
        Enum.reduce(groups, {%{}, %{sets: 0, values: 0}}, fn group, acc ->
          migrate_group(group, opts, acc)
        end)

      attachment_count = migrate_assignments(set_map)

      {:ok, %{sets: counts.sets, values: counts.values, attachments: attachment_count}}
    end
  end

  defp migrate_group(group, opts, acc) do
    full = PhoenixKitCatalogue.Catalogue.get_attribute_group_full(group.uuid)

    Enum.reduce(full.attributes, acc, fn attribute, {set_map, counts} ->
      {set, created?} = find_or_create_migrated_set(group, attribute, opts)

      value_count =
        Enum.count(attribute.values, fn value ->
          ensure_migrated_value(set, value, opts)
        end)

      default = Enum.find(attribute.values, & &1.is_default)

      # Top-up, not created-only: a crash between creating the set and
      # writing its default must not lose the default forever — on
      # re-run the set exists (created? false) but its default is still
      # nil, so apply it then too (panel finding, 2026-08-18 review).
      if default && is_nil(current_default(set)) do
        {:ok, _} = update_set(set, %{default_value_slug: default.key}, opts)
      end

      {
        Map.put(set_map, {group.uuid, attribute.uuid}, set.uuid),
        %{
          counts
          | sets: counts.sets + if(created?, do: 1, else: 0),
            values: counts.values + value_count
        }
      }
    end)
  end

  # Two distinct (group, attribute) pairs can slugify to the same text —
  # "A B"/"C" vs "A"/"B C", or non-Latin names that strip to "" — and a
  # blind slug reuse would silently merge unrelated dimensions (panel
  # finding, 2026-08-18 review). Each migrated set records which legacy
  # attribute it came from (settings.catalogue.migrated_from); on a slug
  # hit for a DIFFERENT attribute the slug is disambiguated with the
  # attribute's stable short uuid, which also keeps re-runs idempotent.
  # A hit without provenance is grandfathered as a match (sets migrated
  # before provenance existed).
  defp find_or_create_migrated_set(group, attribute, opts) do
    base =
      case slugify_name("#{group.name} #{attribute.key}") do
        "" -> "attr_" <> short_uid(attribute)
        slug -> slug
      end

    find_or_create_with_slug(base, group, attribute, opts)
  end

  defp find_or_create_with_slug(slug, group, attribute, opts) do
    full_slug = @slug_prefix <> slug

    case Enum.find(list_sets(), &(&1.name == full_slug)) do
      nil ->
        {create_migrated_set(slug, group, attribute, opts), true}

      %{} = existing ->
        provenance = get_in(existing.settings, ["catalogue", "migrated_from"])

        if provenance in [nil, attribute.uuid] do
          {existing, false}
        else
          find_or_create_with_slug(slug <> "_" <> short_uid(attribute), group, attribute, opts)
        end
    end
  end

  defp create_migrated_set(slug, group, attribute, opts) do
    {:ok, set} =
      create_set(
        %{
          name: "#{group.name} — #{attribute.name}",
          slug: slug,
          kind: attribute.kind
        },
        opts
      )

    {:ok, set} =
      PhoenixKitEntities.update_entity(
        set,
        %{settings: put_in(set.settings, ["catalogue", "migrated_from"], attribute.uuid)},
        on_behalf_of: @owner
      )

    set
  end

  defp short_uid(%{uuid: uuid}) do
    uuid |> String.replace("-", "") |> binary_part(0, 8)
  end

  defp ensure_migrated_value(set, value, opts) do
    existing = list_values(set) |> Enum.any?(&(&1.slug == value.key))

    if existing do
      false
    else
      {:ok, _} = create_value(set, %{label: value.value, slug: value.key}, opts)
      true
    end
  end

  defp migrate_assignments(set_map) do
    assignments =
      repo().all(from(a in PhoenixKitCatalogue.Schemas.ItemAttributeGroup, select: a))

    Enum.reduce(assignments, 0, fn assignment, count ->
      set_uuids =
        set_map
        |> Enum.filter(fn {{group_uuid, _attr}, _set} ->
          group_uuid == assignment.attribute_group_uuid
        end)
        |> Enum.map(fn {_key, set_uuid} -> set_uuid end)

      count + attach_missing(assignment.item_uuid, set_uuids)
    end)
  end

  # attach_set's on_conflict insert reports {:ok, _} for an
  # already-attached pair too — count only genuinely new rows so the
  # idempotency contract ({:ok, all-zeros} on re-run) holds.
  defp attach_missing(item_uuid, set_uuids) do
    existing =
      item_uuid
      |> list_attachments()
      |> MapSet.new(& &1.set_uuid)

    Enum.reduce(set_uuids, 0, fn set_uuid, acc ->
      with false <- MapSet.member?(existing, set_uuid),
           {:ok, _} <- attach_set(item_uuid, set_uuid) do
        acc + 1
      else
        _ -> acc
      end
    end)
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp ensure_enabled do
    if entities_enabled?() do
      :ok
    else
      {:error, :entities_disabled}
    end
  end

  defp validate_kind(kind) when kind in @kinds, do: {:ok, kind}
  defp validate_kind(kind) when kind in [:fixed, :multi], do: {:ok, Atom.to_string(kind)}
  defp validate_kind(_), do: {:error, :invalid_kind}

  defp current_kind(set), do: get_in(set.settings, ["catalogue", "kind"]) || "multi"
  defp current_default(set), do: get_in(set.settings, ["catalogue", "default_value_slug"])

  # Entities enforces two slug dialects: blueprint names allow
  # [a-z0-9_], data-record slugs allow hyphenated [a-z0-9-]. Mirror
  # both — these become the immutable set/value keys.
  defp slugify_name(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
  end

  defp slugify_value(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_extras(attrs, value, extras) when is_map(extras),
    do: Map.put(attrs, :data, Map.merge(value.data || %{}, extras))

  defp maybe_put_extras(attrs, _value, _extras), do: attrs

  defp maybe_put_creator(attrs, opts) do
    case opts[:actor_uuid] do
      uuid when is_binary(uuid) -> Map.put(attrs, :created_by_uuid, uuid)
      _ -> attrs
    end
  end

  defp tap_log({:ok, resource} = result, action, opts, metadata_fn) do
    log_activity(action, opts, metadata_fn.(resource))
    result
  end

  defp tap_log(other, _action, _opts, _metadata_fn), do: other

  defp log_activity(action, opts, metadata) do
    ActivityLog.log(%{
      action: action,
      mode: "manual",
      actor_uuid: opts[:actor_uuid],
      resource_type: "attribute_set",
      metadata: metadata
    })
  end
end
