defmodule PhoenixKitCatalogue.Catalogue.ActivityLog do
  @moduledoc false
  # Shared activity-logging helper used by every Catalogue submodule.
  # Wraps `PhoenixKit.Activity.log/1` with the catalogue module key
  # injected. External plugins must guard with `Code.ensure_loaded?/1`,
  # which we do here once so callers don't have to repeat it.
  #
  # Convention: this module logs on **success** only. Failed mutations
  # surface as `{:error, _}` to the LiveView, which logs the rich error
  # context via its own `log_operation_error/3` (see
  # `web/catalogue_detail_live.ex:425`). The activity log is the user-
  # visible audit trail; operation errors are an engineer-visible log
  # stream. Keeping the two separate prevents validation noise from
  # drowning the audit feed.

  require Logger

  @module_key "catalogue"

  @doc """
  Direct, fire-and-forget log call. Always returns `:ok`.

  Use this from inside transactions, multi-step operations, and the
  module enable/disable callbacks. Never raises — DB hiccups, missing
  table (host hasn't run core's V90 migration), or a mis-shaped Activity
  context all swallow silently with a `Logger.warning`. Returning a
  result from the primary operation must take precedence over logging
  fidelity.
  """
  @spec log(map()) :: :ok
  def log(attrs) when is_map(attrs) do
    if Code.ensure_loaded?(PhoenixKit.Activity) do
      try do
        PhoenixKit.Activity.log(Map.put(attrs, :module, @module_key))
      rescue
        e in Postgrex.Error ->
          # Host hasn't run the activity migration — silent so test DBs
          # without the table don't spam warnings.
          if match?(%{postgres: %{code: :undefined_table}}, e) do
            :ok
          else
            Logger.warning(
              "PhoenixKitCatalogue activity log failed: #{Exception.message(e)} — attrs=#{inspect(Map.take(attrs, [:action, :resource_type, :resource_uuid]))}"
            )
          end

        DBConnection.OwnershipError ->
          # Async PubSub broadcast crossing into a logging path without
          # sandbox checkout (test-only) — swallow per publishing-Batch-5.
          :ok

        error ->
          Logger.warning(
            "PhoenixKitCatalogue activity log failed: #{Exception.message(error)} — attrs=#{inspect(Map.take(attrs, [:action, :resource_type, :resource_uuid]))}"
          )
      catch
        :exit, _reason -> :ok
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
