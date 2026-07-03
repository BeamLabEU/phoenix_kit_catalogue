defmodule PhoenixKitCatalogue.Web.ViewConfig do
  @moduledoc """
  Per-user table view config (columns / sort / filters / view mode) for the
  catalogue admin tables. Stored in `phoenix_kit_users.custom_fields` under
  the `"catalogue_view_configs"` key — no dedicated table. Precedent:
  `PhoenixKit.Notifications.Prefs`.
  """
  alias PhoenixKit.Users.Auth
  alias PhoenixKitCatalogue.Web.TableConfig

  @root "catalogue_view_configs"

  @spec scope_key(TableConfig.scope()) :: String.t()
  def scope_key(scope), do: to_string(scope)

  @spec defaults(TableConfig.scope()) :: map()
  def defaults(scope) do
    {sort_by, sort_dir} = TableConfig.default_sort(scope)

    %{
      columns: TableConfig.default_columns(scope),
      sort_by: sort_by,
      sort_dir: sort_dir,
      filters: %{},
      view: "table"
    }
  end

  @spec load(map() | nil, TableConfig.scope()) :: map()
  def load(user, scope) do
    raw =
      case user do
        %{custom_fields: cf} when is_map(cf) -> get_in(cf, [@root, scope_key(scope)]) || %{}
        _ -> %{}
      end

    normalize(scope, raw)
  end

  @spec normalize(TableConfig.scope(), map()) :: map()
  def normalize(scope, raw) when is_map(raw) do
    d = defaults(scope)

    cols =
      case TableConfig.validate_columns(scope, List.wrap(raw["columns"])) do
        [] -> d.columns
        list -> list
      end

    filters =
      if is_map(raw["filters"]) do
        valid_filter_ids =
          scope
          |> TableConfig.columns()
          |> Enum.filter(& &1.filterable?)
          |> MapSet.new(& &1.id)

        Map.filter(raw["filters"], fn {k, _v} -> MapSet.member?(valid_filter_ids, k) end)
      else
        %{}
      end

    %{
      columns: cols,
      sort_by: raw["sort_by"] || d.sort_by,
      sort_dir: dir(raw["sort_dir"], d.sort_dir),
      filters: filters,
      view: (raw["view"] in ["table", "card"] && raw["view"]) || "table"
    }
  end

  def normalize(scope, _), do: defaults(scope)

  defp dir("desc", _), do: :desc
  defp dir("asc", _), do: :asc
  defp dir(_, fallback), do: fallback

  @spec save(map(), TableConfig.scope(), map()) :: {:ok, map()} | {:error, term()}
  def save(user, scope, cfg) do
    serialized = %{
      "columns" => cfg.columns,
      "sort_by" => cfg.sort_by,
      "sort_dir" => to_string(cfg.sort_dir),
      "filters" => cfg.filters,
      "view" => cfg.view
    }

    current = user.custom_fields || %{}
    scoped = Map.put(Map.get(current, @root, %{}), scope_key(scope), serialized)
    merged = Map.put(current, @root, scoped)

    Auth.update_user_custom_fields(user, merged, ensure_definitions: false, broadcast: false)
  end
end
