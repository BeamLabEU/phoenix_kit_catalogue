defmodule Mix.Tasks.PhoenixKitCatalogue.AuditSupplierRefs do
  @shortdoc "Audit item supplier-info rows for unresolvable supplier UUIDs"

  @moduledoc """
  Reports junction rows in `phoenix_kit_cat_item_supplier_info` whose
  `supplier_uuid` does not resolve in the expected source.

  For `source = 'local'`, resolves against `phoenix_kit_cat_suppliers`.
  For `source = 'crm_company'` or `'crm_contact'`, skips with a note when
  the CRM module is not available.

  Also reports `cat_suppliers` rows that have a non-null `crm_company_uuid`
  (informational — these are local suppliers linked to a CRM company).

  This task is read-only and makes no changes to the database.

  ## Usage

      mix phoenix_kit_catalogue.audit_supplier_refs

  """

  use Mix.Task

  import Ecto.Query

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    repo = PhoenixKit.RepoHelper.repo()
    prefix = Application.get_env(:phoenix_kit, :prefix)

    p = if prefix && prefix != "" && prefix != "public", do: "#{prefix}.", else: ""

    audit_junction_rows(repo, p)
    audit_crm_company_links(repo, p)
  end

  defp audit_junction_rows(repo, p) do
    Mix.shell().info("\n== Supplier-info junction audit ==")

    rows =
      repo.query!(
        "SELECT uuid, item_uuid, supplier_uuid, supplier_source, supplier_name_snapshot " <>
          "FROM #{p}phoenix_kit_cat_item_supplier_info " <>
          "WHERE valid_to IS NULL " <>
          "ORDER BY inserted_at"
      )

    crm_available =
      Code.ensure_loaded?(PhoenixKitCRM.PartyRoles) and
        function_exported?(PhoenixKitCRM.PartyRoles, :get_supplier, 1)

    {unresolvable, crm_skipped, ok} =
      Enum.reduce(rows.rows, {[], [], []}, fn [uuid, item_uuid, supplier_uuid, source, snapshot],
                                              {unresolvable, crm_skipped, ok} ->
        case source do
          "local" ->
            found =
              repo.exists?(
                from(s in PhoenixKitCatalogue.Schemas.Supplier, where: s.uuid == ^supplier_uuid)
              )

            if found do
              {unresolvable, crm_skipped, [uuid | ok]}
            else
              {[{uuid, item_uuid, supplier_uuid, source, snapshot} | unresolvable], crm_skipped,
               ok}
            end

          src when src in ["crm_company", "crm_contact"] ->
            if crm_available do
              case apply(PhoenixKitCRM.PartyRoles, :get_supplier, [supplier_uuid]) do
                nil ->
                  {[{uuid, item_uuid, supplier_uuid, source, snapshot} | unresolvable],
                   crm_skipped, ok}

                _party ->
                  {unresolvable, crm_skipped, [uuid | ok]}
              end
            else
              {unresolvable, [{uuid, source} | crm_skipped], ok}
            end

          _other ->
            {unresolvable, crm_skipped, ok}
        end
      end)

    total = length(rows.rows)
    Mix.shell().info("Total junction rows: #{total}")
    Mix.shell().info("OK (resolved): #{length(ok)}")

    if crm_skipped != [] do
      Mix.shell().info(
        "CRM module not available — skipped #{length(crm_skipped)} CRM-sourced rows:"
      )

      Enum.each(crm_skipped, fn {uuid, source} ->
        Mix.shell().info("  row=#{uuid} source=#{source}")
      end)
    end

    if unresolvable == [] do
      Mix.shell().info("No unresolvable supplier UUIDs found.")
    else
      Mix.shell().error("Unresolvable supplier UUIDs (#{length(unresolvable)}):")

      Enum.each(unresolvable, fn {uuid, item_uuid, supplier_uuid, source, snapshot} ->
        Mix.shell().error(
          "  row=#{uuid} item=#{item_uuid} supplier=#{supplier_uuid} " <>
            "source=#{source} snapshot=#{inspect(snapshot)}"
        )
      end)
    end
  end

  defp audit_crm_company_links(repo, p) do
    Mix.shell().info("\n== Suppliers with crm_company_uuid links (informational) ==")

    rows =
      repo.query!(
        "SELECT uuid, name, crm_company_uuid " <>
          "FROM #{p}phoenix_kit_cat_suppliers " <>
          "WHERE crm_company_uuid IS NOT NULL " <>
          "ORDER BY name"
      )

    if rows.rows == [] do
      Mix.shell().info("No local suppliers linked to a CRM company.")
    else
      Mix.shell().info("#{length(rows.rows)} local supplier(s) linked to a CRM company:")

      Enum.each(rows.rows, fn [uuid, name, crm_uuid] ->
        Mix.shell().info("  supplier=#{uuid} name=#{name} crm_company=#{crm_uuid}")
      end)
    end
  end
end
