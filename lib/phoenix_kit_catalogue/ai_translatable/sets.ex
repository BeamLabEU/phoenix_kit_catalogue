defmodule PhoenixKitCatalogue.AITranslatable.Sets do
  @moduledoc """
  `PhoenixKitAI.Translatable` adapter for catalogue attribute SETS — the
  entities-backed blueprint (`"catalogue_set_label"`, the set's own display
  name) and its value records (`"catalogue_set_value"`, each value's title).
  See `PhoenixKitCatalogue.Catalogue.AttributeSets` for what a set is; this
  module only translates it.

  Unlike `PhoenixKitCatalogue.AITranslatable`, both resources here are
  entities schemas (`PhoenixKitEntities` / `PhoenixKitEntities.EntityData`),
  not catalogue's own — and their generic writers (`update_entity/3`,
  `EntityData.update/2`) do not lock the row. Same doctrine as the
  item/category adapter: `put_translation/4` re-reads the row `FOR UPDATE`
  inside its own transaction before merging, so two concurrent per-language
  jobs (de/fr) on the same set or value serialize on the row lock instead of
  each overwriting the other's translation from a stale in-memory struct.

  The merge itself is NOT duplicated here — it re-uses the entities
  package's own translation helpers
  (`PhoenixKitEntities.set_entity_translation/3`,
  `PhoenixKitEntities.EntityData.set_title_translation/3`) against the
  freshly-locked row. Both already satisfy the "never drop other languages"
  contract this adapter needs; only the lock was missing, and the
  surrounding transaction supplies exactly that.
  """

  @behaviour PhoenixKitAI.Translatable

  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.EntityData
  alias PhoenixKitEntities.Managed

  @owner "catalogue"

  defp repo, do: RepoHelper.repo()

  @impl true
  def fetch("catalogue_set_label", uuid) do
    case Entities.get_entity(uuid) do
      %Entities{} = set -> owned_or_not_found(set, set)
      nil -> not_found()
    end
  end

  def fetch("catalogue_set_value", uuid) do
    case EntityData.get(uuid) do
      %EntityData{} = value -> owned_or_not_found(Entities.get_entity(value.entity_uuid), value)
      nil -> not_found()
    end
  end

  def fetch(other, _uuid), do: {:error, {:unknown_resource_type, other}}

  # `set` is the blueprint whose ownership gates access; `resource` is what
  # gets returned on success (the set itself for the label type, the value
  # record for the value type).
  defp owned_or_not_found(%Entities{} = set, resource) do
    if Managed.owner(set) == @owner, do: {:ok, resource}, else: not_found()
  end

  defp owned_or_not_found(_set, _resource), do: not_found()

  defp not_found, do: {:error, :resource_not_found}

  @impl true
  def source_fields(%Entities{} = set, source_lang) do
    label = Entities.get_entity_translation(set, source_lang)["display_name"]
    put_if_present(%{}, "label", label)
  end

  def source_fields(%EntityData{} = value, source_lang) do
    title = EntityData.get_title_translation(value, source_lang)
    put_if_present(%{}, "title", title)
  end

  defp put_if_present(map, key, value) when is_binary(value) do
    if String.trim(value) == "", do: map, else: Map.put(map, key, value)
  end

  defp put_if_present(map, _key, _value), do: map

  @impl true
  def put_translation(%Entities{} = set, target_lang, fields, _opts) do
    case Map.fetch(fields, "label") do
      {:ok, label} -> put_set_label(set, target_lang, label)
      :error -> {:ok, set}
    end
  end

  def put_translation(%EntityData{} = value, target_lang, fields, _opts) do
    case Map.fetch(fields, "title") do
      {:ok, title} -> put_value_title(value, target_lang, title)
      :error -> {:ok, value}
    end
  end

  defp put_set_label(set, target_lang, label) do
    locked_update(Entities, set.uuid, fn fresh ->
      Entities.set_entity_translation(fresh, target_lang, %{"display_name" => label})
    end)
  end

  defp put_value_title(value, target_lang, title) do
    locked_update(EntityData, value.uuid, fn fresh ->
      EntityData.set_title_translation(fresh, target_lang, title)
    end)
  end

  # Re-reads `uuid` FOR UPDATE inside a fresh transaction, then hands the
  # locked row to `update_fn` — the shared shape behind both writes above.
  defp locked_update(queryable, uuid, update_fn) do
    repo().transaction(fn ->
      query = where(queryable, [r], r.uuid == ^uuid) |> lock("FOR UPDATE")

      case repo().one(query) do
        nil -> repo().rollback(:resource_not_found)
        fresh -> apply_locked_update(update_fn, fresh)
      end
    end)
  end

  defp apply_locked_update(update_fn, fresh) do
    case update_fn.(fresh) do
      {:ok, updated} -> updated
      {:error, reason} -> repo().rollback(reason)
    end
  end
end
