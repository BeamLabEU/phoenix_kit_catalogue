defmodule PhoenixKitCatalogueTest do
  use ExUnit.Case

  describe "behaviour implementation" do
    test "implements PhoenixKit.Module" do
      behaviours =
        PhoenixKitCatalogue.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert PhoenixKit.Module in behaviours
    end

    test "has @phoenix_kit_module attribute for auto-discovery" do
      attrs = PhoenixKitCatalogue.__info__(:attributes)
      assert Keyword.get(attrs, :phoenix_kit_module) == [true]
    end
  end

  describe "required callbacks" do
    test "module_key/0 returns catalogue" do
      assert PhoenixKitCatalogue.module_key() == "catalogue"
    end

    test "module_name/0 returns Catalogue" do
      assert PhoenixKitCatalogue.module_name() == "Catalogue"
    end

    test "enabled?/0 returns a boolean" do
      assert is_boolean(PhoenixKitCatalogue.enabled?())
    end

    test "enable_system/0 is exported" do
      assert function_exported?(PhoenixKitCatalogue, :enable_system, 0)
    end

    test "disable_system/0 is exported" do
      assert function_exported?(PhoenixKitCatalogue, :disable_system, 0)
    end
  end

  describe "permission_metadata/0" do
    test "returns a map with required fields" do
      meta = PhoenixKitCatalogue.permission_metadata()
      assert %{key: key, label: label, icon: icon, description: desc} = meta
      assert is_binary(key)
      assert is_binary(label)
      assert is_binary(icon)
      assert is_binary(desc)
    end

    test "key matches module_key" do
      meta = PhoenixKitCatalogue.permission_metadata()
      assert meta.key == PhoenixKitCatalogue.module_key()
    end

    test "icon uses hero- prefix" do
      meta = PhoenixKitCatalogue.permission_metadata()
      assert String.starts_with?(meta.icon, "hero-")
    end
  end

  describe "admin_tabs/0" do
    test "returns a list of Tab structs" do
      tabs = PhoenixKitCatalogue.admin_tabs()
      assert is_list(tabs)
      assert tabs != []
    end

    test "main tab has required fields" do
      [tab | _] = PhoenixKitCatalogue.admin_tabs()
      assert tab.id == :admin_catalogue
      assert tab.label == "Catalogue"
      assert is_binary(tab.path)
      assert tab.level == :admin
      assert tab.permission == PhoenixKitCatalogue.module_key()
      assert tab.group == :admin_modules
    end

    test "main tab has live_view for route generation" do
      [tab | _] = PhoenixKitCatalogue.admin_tabs()
      assert {PhoenixKitCatalogue.Web.CataloguesLive, :index} = tab.live_view
    end

    test "all tabs have permission matching module_key" do
      for tab <- PhoenixKitCatalogue.admin_tabs() do
        assert tab.permission == PhoenixKitCatalogue.module_key()
      end
    end

    test "all subtabs reference parent" do
      [main | subtabs] = PhoenixKitCatalogue.admin_tabs()

      for tab <- subtabs do
        assert tab.parent == main.id
      end
    end
  end

  describe "version/0" do
    test "returns version string" do
      assert PhoenixKitCatalogue.version() == "0.2.0"
    end
  end

  describe "optional callbacks" do
    test "get_config/0 returns a map" do
      config = PhoenixKitCatalogue.get_config()
      assert is_map(config)
      assert Map.has_key?(config, :enabled)
    end

    test "settings_tabs/0 returns empty list" do
      assert PhoenixKitCatalogue.settings_tabs() == []
    end

    test "user_dashboard_tabs/0 returns empty list" do
      assert PhoenixKitCatalogue.user_dashboard_tabs() == []
    end

    test "children/0 returns empty list" do
      assert PhoenixKitCatalogue.children() == []
    end

    test "route_module/0 returns nil" do
      assert PhoenixKitCatalogue.route_module() == nil
    end
  end
end
