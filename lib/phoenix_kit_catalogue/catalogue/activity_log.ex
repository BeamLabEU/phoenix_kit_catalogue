defmodule PhoenixKitCatalogue.Catalogue.ActivityLog do
  @moduledoc false
  # Shared activity-logging helper used by every Catalogue submodule.
  # Wraps `PhoenixKit.Activity.log/1` with the catalogue module key
  # injected. External plugins must guard with `Code.ensure_loaded?/1`,
  # which we do here once so callers don't have to repeat it.

  require Logger

  @module_key "catalogue"

  @spec log(map()) :: :ok
  def log(attrs) when is_map(attrs) do
    # Activity logging must never crash the primary operation. If the
    # Activity context raises (e.g. DB hiccup, misconfigured module), we
    # swallow it with a Logger warning so the caller's mutation succeeds.
    if Code.ensure_loaded?(PhoenixKit.Activity) do
      try do
        PhoenixKit.Activity.log(Map.put(attrs, :module, @module_key))
      rescue
        error ->
          Logger.warning(
            "PhoenixKitCatalogue activity log failed: #{Exception.message(error)} — attrs=#{inspect(Map.take(attrs, [:action, :resource_type, :resource_uuid]))}"
          )
      end
    end

    :ok
  end

  @doc """
  Runs `op_fun` and, on `{:ok, _}`, logs an activity entry with `attrs_fun(record)`.
  Collapses the repeating `case Repo.insert(...) do {:ok, x} = ok -> log; ok; ... end`
  pattern that appears across every CRUD function.

  `op_fun` should return `{:ok, record} | {:error, anything}`. `attrs_fun` is
  only called on success and receives the inserted/updated record.
  """
  @spec with_log((-> {:ok, term()} | {:error, term()}), (term() -> map())) ::
          {:ok, term()} | {:error, term()}
  def with_log(op_fun, attrs_fun) when is_function(op_fun, 0) and is_function(attrs_fun, 1) do
    case op_fun.() do
      {:ok, record} = ok ->
        log(attrs_fun.(record))
        ok

      {:error, _} = err ->
        err
    end
  end
end
