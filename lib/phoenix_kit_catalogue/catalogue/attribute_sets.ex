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

  defp entities_enabled? do
    # Requires the Managed API (entities > 0.4.0) — on an older entities
    # package the whole feature reports :entities_disabled rather than
    # crashing on missing functions.
    Code.ensure_loaded?(PhoenixKitEntities) and
      Code.ensure_loaded?(PhoenixKitEntities.Managed) and
      PhoenixKitEntities.enabled?()
  end

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
      start: {Task, :start_link, [&register_deletion_guard/0]},
      restart: :temporary
    }
  end

  @doc false
  def register_deletion_guard do
    if Code.ensure_loaded?(PhoenixKitEntities.Managed) do
      PhoenixKitEntities.Managed.register_delete_guard(@owner, &deletion_guard/1)
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
    with :ok <- ensure_enabled(),
         # Checked here AND via the registered entities-side guard:
         # this path must be correct even on a host that never ran the
         # supervision-tree registration (belt and suspenders).
         false <- set_attached?(set.uuid) do
      PhoenixKitEntities.delete_entity(set, on_behalf_of: @owner)
      |> tap_log("attribute_set.deleted", opts, fn s ->
        %{"name" => s.display_name, "slug" => s.name}
      end)
    else
      true -> {:error, :set_in_use}
      {:error, reason} -> {:error, reason}
    end
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

  @doc "Attaches a set to an item (appends; no-op when already attached)."
  @spec attach_set(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, ItemAttributeSet.t()} | {:error, term()}
  def attach_set(item_uuid, set_uuid, opts \\ []) do
    with :ok <- ensure_enabled(),
         %{} <- get_set(set_uuid) || {:error, :set_not_found} do
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
      |> tap_log("attribute_set.attached", opts, fn _ ->
        %{"item_uuid" => item_uuid, "set_uuid" => set_uuid}
      end)
    end
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

  @doc "Removes attachments whose set blueprint no longer exists (PubSub cleanup)."
  @spec prune_orphan_attachments(Ecto.UUID.t()) :: non_neg_integer()
  def prune_orphan_attachments(set_uuid) do
    if get_set(set_uuid) do
      0
    else
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
        sets = rows |> Enum.map(&resolved_sets[&1.set_uuid]) |> Enum.reject(&is_nil/1)
        {item_uuid, %{schema_version: 2, sets: sets}}
      end)
    else
      %{}
    end
  end

  @doc "Single-item convenience over `resolve_for_items/2`."
  @spec resolve_for_item(Ecto.UUID.t(), keyword()) :: map()
  def resolve_for_item(item_uuid, opts \\ []) do
    resolve_for_items([item_uuid], opts)
    |> Map.get(item_uuid, %{schema_version: 2, sets: []})
  end

  defp resolve_set(set_uuid, opts) do
    with %{} = set <- get_set(set_uuid, opts),
         {:ok, %{kind: kind, default: default}} <- contract(set) do
      values =
        set_uuid
        |> list_values(opts)
        |> Enum.map(fn record ->
          %{key: record.slug, label: record.title, extras: record.data || %{}}
        end)

      %{
        uuid: set_uuid,
        key: set.name,
        name: set.display_name,
        kind: kind,
        default: default,
        values: values
      }
    else
      nil ->
        nil

      {:error, :contract_broken} ->
        Logger.warning("AttributeSets: contract broken for set #{inspect(set_uuid)} — skipped")
        nil
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
      slug = slugify_name("#{group.name} #{attribute.key}")

      {set, created?} = find_or_create_migrated_set(slug, group, attribute, opts)

      value_count =
        Enum.count(attribute.values, fn value ->
          ensure_migrated_value(set, value, opts)
        end)

      default = Enum.find(attribute.values, & &1.is_default)

      if created? and default do
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

  defp find_or_create_migrated_set(slug, group, attribute, opts) do
    full_slug = @slug_prefix <> slug

    case Enum.find(list_sets(), &(&1.name == full_slug)) do
      %{} = existing ->
        {existing, false}

      nil ->
        {:ok, set} =
          create_set(
            %{
              name: "#{group.name} — #{attribute.name}",
              slug: slug,
              kind: attribute.kind
            },
            opts
          )

        {set, true}
    end
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
