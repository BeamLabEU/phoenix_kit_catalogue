defmodule PhoenixKitCatalogue.Web.SettingsPermissionTest do
  @moduledoc """
  `catalogue.settings` — Settings → Catalogues (the AI translation sweep and
  the list and item-form preferences) sits behind the sub-key, not the
  everyday `catalogue` key. The page refuses a base-only scope at mount,
  every write event re-checks the scope the socket holds at that moment,
  and the one-time backfill carries the roles that held `catalogue` across.
  """
  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.{Permissions, Roles}
  alias PhoenixKitCatalogue.Test.Repo, as: TestRepo
  alias PhoenixKitCatalogue.Web.Settings, as: CatalogueSettings

  @path "/en/admin/settings/catalogues"
  @sub "catalogue.settings"
  @flag "catalogue_settings_backfilled"

  setup do
    register_catalogue_module()
    :ok
  end

  defp base_only, do: permission_scope(["catalogue"])
  defp holder, do: permission_scope(["catalogue", @sub])

  # What core's live scope refresh does when a role loses a grant while the
  # page is open.
  defp swap_scope(view, scope) do
    :sys.replace_state(view.pid, fn %{socket: socket} = state ->
      %{state | socket: Phoenix.Component.assign(socket, :phoenix_kit_current_scope, scope)}
    end)
  end

  describe "the sub-key" do
    test "is declared on the module and checked with Scope.can?/2" do
      assert %{sub_permissions: [%{key: "settings"}]} = PhoenixKitCatalogue.permission_metadata()
      assert PhoenixKitCatalogue.settings_permission() == @sub

      assert PhoenixKitCatalogue.can_change_settings?(holder())
      refute PhoenixKitCatalogue.can_change_settings?(base_only())
      # A sub-key without its base is no grant.
      refute PhoenixKitCatalogue.can_change_settings?(permission_scope([@sub]))
      refute PhoenixKitCatalogue.can_change_settings?(nil)
    end

    test "the settings tab carries it" do
      [tab] = PhoenixKitCatalogue.settings_tabs()
      assert tab.permission == @sub
      assert tab.live_view == {PhoenixKitCatalogue.Web.SettingsLive, :settings}
    end
  end

  describe "the settings page" do
    test "the base key alone is refused at mount", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
               live(with_permissions(conn, ["catalogue"]), @path)

      refute to =~ "/settings"
      assert flash["error"] =~ "permission"
    end

    test "a holder opens it", %{conn: conn} do
      {:ok, view, _html} = live(with_permissions(conn, ["catalogue", @sub]), @path)
      assert has_element?(view, "#catalogue-sweep-form")
    end

    test "every write event re-checks the sub-key", %{conn: conn} do
      {:ok, _} = CatalogueSettings.update_context_menu_enabled(true)
      {:ok, _} = CatalogueSettings.update_seo_fields_visible(false)
      {:ok, _} = CatalogueSettings.update_sweep_enabled(false)
      {:ok, _} = CatalogueSettings.update_sweep_interval_minutes(60)
      {:ok, _} = CatalogueSettings.update_sweep_max_per_run(200)
      # A stored selection, read back raw: an unticked group posts nothing,
      # so an ungated `save_sweep_langs` would overwrite it with none.
      {:ok, _} = CatalogueSettings.update_sweep_langs(["et"])

      {:ok, view, _html} = live(with_permissions(conn, ["catalogue", @sub]), @path)
      swap_scope(view, base_only())

      html = render_click(view, "toggle_context_menu", %{"value" => "false"})
      assert html =~ "permission"
      assert CatalogueSettings.context_menu_enabled?()

      render_click(view, "toggle_seo_fields", %{"value" => "true"})
      refute CatalogueSettings.seo_fields_visible?()

      render_click(view, "toggle_sweep", %{"value" => "true"})
      refute CatalogueSettings.sweep_enabled?()

      render_click(view, "save_sweep_interval", %{"value" => "5"})
      assert CatalogueSettings.sweep_interval_minutes() == 60

      render_click(view, "save_sweep_max_per_run", %{"value" => "9999"})
      assert CatalogueSettings.sweep_max_per_run() == 200

      render_click(view, "save_sweep_langs", %{})

      assert Settings.get_json_setting("catalogue_translation_sweep_langs") == %{
               "codes" => ["et"]
             }
    end

    test "a holder's write still goes through", %{conn: conn} do
      {:ok, _} = CatalogueSettings.update_sweep_interval_minutes(60)
      {:ok, view, _html} = live(with_permissions(conn, ["catalogue", @sub]), @path)

      render_click(view, "save_sweep_interval", %{"value" => "15"})
      assert CatalogueSettings.sweep_interval_minutes() == 15
    end
  end

  describe "the one-time backfill" do
    defp role_with_base! do
      n = System.unique_integer([:positive])
      {:ok, role} = Roles.create_role(%{"name" => "CatRole-#{n}", "description" => "test"})
      {:ok, _} = Permissions.grant_permission(role.uuid, "catalogue", nil)
      role
    end

    defp holds?(role, key), do: key in Permissions.get_permissions_for_role(role.uuid)

    test "grants the sub-key once to roles holding the base key, then sets the flag" do
      holder = role_with_base!()
      {:ok, bystander} = Roles.create_role(%{"name" => "NoCat-#{System.unique_integer()}"})

      assert :ok = PhoenixKitCatalogue.migrate_legacy()
      assert holds?(holder, @sub)
      refute holds?(bystander, @sub)
      assert Settings.get_setting(@flag) == "true"

      late = role_with_base!()
      assert :ok = PhoenixKitCatalogue.migrate_legacy()
      refute holds?(late, @sub)
    end

    test "a revoke after the backfill sticks across boots" do
      holder = role_with_base!()
      :ok = PhoenixKitCatalogue.migrate_legacy()
      :ok = Permissions.revoke_permission(holder.uuid, @sub)

      :ok = PhoenixKitCatalogue.migrate_legacy()
      refute holds?(holder, @sub)
    end

    test "a failed grant leaves the flag unset so the next boot retries" do
      holder = role_with_base!()

      assert {:error, {:grants_failed, n}} =
               PhoenixKitCatalogue.backfill_settings_permission(fn _, _, _ -> {:error, :boom} end)

      assert n >= 1
      refute holds?(holder, @sub)
      refute Settings.get_setting(@flag) == "true"

      assert :ok = PhoenixKitCatalogue.migrate_legacy()
      assert holds?(holder, @sub)
      assert Settings.get_setting(@flag) == "true"
    end

    # Core's `get_permissions_for_role/1` rescues a query error to `[]`, which
    # would read as "nobody holds the base key" and set the flag for good.
    test "a failed grant lookup is an error, and the flag stays unset" do
      _holder = role_with_base!()

      # DDL inside the test's sandbox transaction, undone with it.
      TestRepo.query!("ALTER TABLE phoenix_kit_role_permissions RENAME TO pk_rp_hidden")
      result = PhoenixKitCatalogue.migrate_legacy()
      TestRepo.query!("ALTER TABLE pk_rp_hidden RENAME TO phoenix_kit_role_permissions")

      assert result == {:error, :lookup_failed}
      refute Settings.get_setting(@flag) == "true"
    end
  end
end
