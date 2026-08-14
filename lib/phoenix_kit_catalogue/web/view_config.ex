defmodule PhoenixKitCatalogue.Web.ViewConfig do
  @moduledoc """
  Per-user table view config (columns / sort / filters / view mode) for the
  catalogue admin tables. Stored in `phoenix_kit_users.custom_fields` under
  the `"catalogue_view_configs"` key — no dedicated table. Precedent:
  `PhoenixKit.Notifications.Prefs`.

  ## Global sort

  For scopes in `@global_sort_scopes` the SORT half of the config is not
  per-user: it lives in a module setting (`catalogue_sort_<scope>`), so every
  admin sees the same ordering — when one of them switches the catalogues
  index to "Manual order" and drags rows, everyone else is looking at that
  same order (the live half rides `Catalogue.PubSub`; see
  `broadcast_view_sort_changed/4` and `CataloguesLive.put_cfg/3`).
  `load/2` overlays the global value over whatever the user row stored, so
  the per-user copy is inert for these scopes. Columns / filters / view mode
  stay per-user everywhere.
  """
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKitCatalogue.Web.TableConfig

  @root "catalogue_view_configs"

  # Only the catalogues index for now — deliberately not manufacturers /
  # suppliers, and not a per-scope TableConfig flag: the boss wants exactly
  # this one table shared. Widen the list when that changes.
  @global_sort_scopes [:catalogues]

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

  @spec global_sort?(TableConfig.scope()) :: boolean()
  def global_sort?(scope), do: scope in @global_sort_scopes

  defp global_sort_setting_key(scope), do: "catalogue_sort_" <> scope_key(scope)

  @doc """
  The shared sort for a global-sort scope: the `catalogue_sort_<scope>`
  setting (`"<column>:<asc|desc>"`), falling back to the scope's default
  when unset or when it names a column that is no longer sortable.
  """
  @spec load_global_sort(TableConfig.scope()) :: {String.t(), :asc | :desc}
  def load_global_sort(scope) do
    fallback = TableConfig.default_sort(scope)

    case Settings.get_setting(global_sort_setting_key(scope), nil) do
      value when is_binary(value) -> parse_global_sort(scope, value, fallback)
      _ -> fallback
    end
  end

  defp parse_global_sort(scope, value, fallback) do
    with [by, dir_s] <- String.split(value, ":", parts: 2),
         true <- sortable_id?(scope, by),
         dir when is_atom(dir) <- (dir_s == "asc" && :asc) || (dir_s == "desc" && :desc) do
      {by, dir}
    else
      _ -> fallback
    end
  end

  defp sortable_id?(scope, id) do
    scope |> TableConfig.columns() |> Enum.any?(&(&1.id == id and &1.sortable?))
  end

  @spec save_global_sort(TableConfig.scope(), String.t(), :asc | :desc) ::
          {:ok, term()} | {:error, term()}
  def save_global_sort(scope, sort_by, sort_dir) do
    Settings.update_setting_with_module(
      global_sort_setting_key(scope),
      "#{sort_by}:#{sort_dir}",
      PhoenixKitCatalogue.module_key()
    )
  end

  @spec load(map() | nil, TableConfig.scope()) :: map()
  def load(user, scope) do
    raw =
      case user do
        %{custom_fields: cf} when is_map(cf) -> get_in(cf, [@root, scope_key(scope)]) || %{}
        _ -> %{}
      end

    cfg = normalize(scope, raw)

    if global_sort?(scope) do
      {sort_by, sort_dir} = load_global_sort(scope)
      %{cfg | sort_by: sort_by, sort_dir: sort_dir}
    else
      cfg
    end
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

  @spec save(map() | nil, TableConfig.scope(), map()) :: {:ok, map()} | {:error, term()}
  def save(%Auth.User{} = user, scope, cfg) do
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

  # `update_user_custom_fields/3` matches a real `%Auth.User{}`; anything else
  # (nil, or the bare `%{uuid: uuid}` the LV test harness mounts with) used to
  # raise out of `put_cfg` and crash the LiveView on the first sort click.
  # Per-user persistence is best-effort — skip it rather than crash; callers
  # already treat any non-{:ok, user} as "keep the in-memory cfg only".
  def save(_user, _scope, _cfg), do: {:error, :no_user}
end
