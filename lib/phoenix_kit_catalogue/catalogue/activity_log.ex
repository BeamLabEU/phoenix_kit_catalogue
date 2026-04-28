defmodule PhoenixKitCatalogue.Catalogue.ActivityLog do
  @moduledoc false
  # Shared activity-logging helper used by every Catalogue submodule.
  # Wraps `PhoenixKit.Activity.log/1` with the catalogue module key
  # injected. External plugins must guard with `Code.ensure_loaded?/1`,
  # which we do here once so callers don't have to repeat it.
  #
  # ## Convention — layered logging
  #
  # The context layer (this module's callers — `Catalogue`, `Rules`,
  # `Manufacturers`, etc.) logs on **success only**. Validation errors
  # never reach the audit feed: they're handled by the LV's
  # `assign_form/2` cycle and never persisted as audit rows.
  #
  # The LV layer logs on **both branches** via
  # `PhoenixKitCatalogue.Web.Helpers.log_operation_error/3` (added in
  # the 2026-04-28 re-validation Batch 4). On `{:error, _}`-from-
  # context failures — FK violations, stale-entry races, downstream
  # cascade refusals — the helper writes the same action atom the
  # success path would have written, with `metadata.db_pending: true`
  # so audit-feed readers can filter or highlight failed attempts.
  #
  # The two layers solve different problems and coexist:
  #
  #   * **Engineer-visible** errors flow through `Logger.error` with
  #     full changeset/atom context for production-incident triage.
  #   * **User-visible** audit rows capture user *intent* — a
  #     legitimate attempted action that failed is still audit-worthy
  #     for security and forensic purposes.
  #
  # Validation cycles never produce audit noise because
  # `log_operation_error/3` is only called from `handle_event`
  # `{:error, _}` branches that the form's error display didn't
  # already handle.

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
