defmodule PhoenixKitCatalogue do
  @moduledoc """
  Catalogue module for PhoenixKit.

  Manages product catalogues with manufacturers, suppliers, categories, and items.
  Designed for manufacturing companies (e.g., kitchen/furniture producers) that need
  to organize materials and components from multiple manufacturers and suppliers.

  ## Installation

  Add to your parent app's `mix.exs`:

      {:phoenix_kit_catalogue, path: "../phoenix_kit_catalogue"}

  Then `mix deps.get`. The module auto-discovers via beam scanning.
  Enable it in Admin > Modules.

  ## Structure

  - **Manufacturers** — companies that produce materials/components
  - **Suppliers** — companies that deliver materials (many-to-many with manufacturers)
  - **Catalogues** — top-level groupings (e.g., "Kitchen Furniture", "Plumbing")
  - **Categories** — subdivisions within a catalogue (e.g., "Cabinet Frames", "Doors")
  - **Items** — individual products with SKU, price, unit of measure
  """

  use PhoenixKit.Module

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Settings

  # ===========================================================================
  # Required callbacks
  # ===========================================================================

  @impl PhoenixKit.Module
  def module_key, do: "catalogue"

  @impl PhoenixKit.Module
  def module_name, do: "Catalogue"

  @impl PhoenixKit.Module
  def enabled? do
    Settings.get_boolean_setting("catalogue_enabled", false)
  rescue
    _ -> false
  end

  @impl PhoenixKit.Module
  def enable_system do
    Settings.update_boolean_setting_with_module("catalogue_enabled", true, module_key())
  end

  @impl PhoenixKit.Module
  def disable_system do
    Settings.update_boolean_setting_with_module("catalogue_enabled", false, module_key())
  end

  # ===========================================================================
  # Optional callbacks
  # ===========================================================================

  @impl PhoenixKit.Module
  def version, do: "0.2.0"

  @impl PhoenixKit.Module
  def css_sources, do: [:phoenix_kit_catalogue]

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: module_key(),
      label: "Catalogue",
      icon: "hero-rectangle-stack",
      description: "Product catalogue management for manufacturers and suppliers"
    }
  end

  @impl PhoenixKit.Module
  def admin_tabs do
    [
      # Main tab — parent container, redirects to first subtab.
      # match: :prefix keeps subtabs open on any /catalogue/* subpage;
      # highlight_with_subtabs: false suppresses parent highlight when a subtab is active.
      # Note: parent highlights on hidden subpages (e.g. /catalogue/new) — acceptable tradeoff.
      %Tab{
        id: :admin_catalogue,
        label: "Catalogue",
        icon: "hero-rectangle-stack",
        path: "catalogue",
        priority: 660,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        group: :admin_modules,
        subtab_display: :when_active,
        highlight_with_subtabs: false,
        redirect_to_first_subtab: true,
        live_view: {PhoenixKitCatalogue.Web.CataloguesLive, :index}
      },
      # Subtabs — Catalogues, Manufacturers, Suppliers
      %Tab{
        id: :admin_catalogue_list,
        label: "Catalogues",
        icon: "hero-rectangle-stack",
        path: "catalogue",
        priority: 661,
        level: :admin,
        permission: module_key(),
        match: :exact,
        parent: :admin_catalogue,
        live_view: {PhoenixKitCatalogue.Web.CataloguesLive, :index}
      },
      %Tab{
        id: :admin_catalogue_manufacturers,
        label: "Manufacturers",
        icon: "hero-building-office",
        path: "catalogue/manufacturers",
        priority: 662,
        level: :admin,
        permission: module_key(),
        parent: :admin_catalogue,
        live_view: {PhoenixKitCatalogue.Web.CataloguesLive, :manufacturers}
      },
      %Tab{
        id: :admin_catalogue_suppliers,
        label: "Suppliers",
        icon: "hero-truck",
        path: "catalogue/suppliers",
        priority: 663,
        level: :admin,
        permission: module_key(),
        parent: :admin_catalogue,
        live_view: {PhoenixKitCatalogue.Web.CataloguesLive, :suppliers}
      },
      # Static paths MUST come before wildcard :uuid paths
      # so Phoenix router matches them first.

      # Catalogue — static paths
      %Tab{
        id: :admin_catalogue_new,
        label: "New Catalogue",
        icon: "hero-plus",
        path: "catalogue/new",
        priority: 664,
        level: :admin,
        permission: module_key(),
        parent: :admin_catalogue,
        visible: false,
        live_view: {PhoenixKitCatalogue.Web.CatalogueFormLive, :new}
      },
      %Tab{
        id: :admin_catalogue_manufacturer_new,
        label: "New Manufacturer",
        icon: "hero-plus",
        path: "catalogue/manufacturers/new",
        priority: 665,
        level: :admin,
        permission: module_key(),
        parent: :admin_catalogue,
        visible: false,
        live_view: {PhoenixKitCatalogue.Web.ManufacturerFormLive, :new}
      },
      %Tab{
        id: :admin_catalogue_manufacturer_edit,
        label: "Edit Manufacturer",
        icon: "hero-pencil-square",
        path: "catalogue/manufacturers/:uuid/edit",
        priority: 666,
        level: :admin,
        permission: module_key(),
        parent: :admin_catalogue,
        visible: false,
        live_view: {PhoenixKitCatalogue.Web.ManufacturerFormLive, :edit}
      },
      %Tab{
        id: :admin_catalogue_supplier_new,
        label: "New Supplier",
        icon: "hero-plus",
        path: "catalogue/suppliers/new",
        priority: 667,
        level: :admin,
        permission: module_key(),
        parent: :admin_catalogue,
        visible: false,
        live_view: {PhoenixKitCatalogue.Web.SupplierFormLive, :new}
      },
      %Tab{
        id: :admin_catalogue_supplier_edit,
        label: "Edit Supplier",
        icon: "hero-pencil-square",
        path: "catalogue/suppliers/:uuid/edit",
        priority: 668,
        level: :admin,
        permission: module_key(),
        parent: :admin_catalogue,
        visible: false,
        live_view: {PhoenixKitCatalogue.Web.SupplierFormLive, :edit}
      },
      # Categories — static edit path before catalogue :uuid wildcard
      %Tab{
        id: :admin_catalogue_category_edit,
        label: "Edit Category",
        icon: "hero-pencil-square",
        path: "catalogue/categories/:uuid/edit",
        priority: 669,
        level: :admin,
        permission: module_key(),
        parent: :admin_catalogue,
        visible: false,
        live_view: {PhoenixKitCatalogue.Web.CategoryFormLive, :edit}
      },
      # Items — static edit path before catalogue :uuid wildcard
      %Tab{
        id: :admin_catalogue_item_edit,
        label: "Edit Item",
        icon: "hero-pencil-square",
        path: "catalogue/items/:uuid/edit",
        priority: 670,
        level: :admin,
        permission: module_key(),
        parent: :admin_catalogue,
        visible: false,
        live_view: {PhoenixKitCatalogue.Web.ItemFormLive, :edit}
      },
      # Wildcard :uuid routes LAST — these catch anything not matched above
      %Tab{
        id: :admin_catalogue_detail,
        label: "Catalogue",
        icon: "hero-rectangle-stack",
        path: "catalogue/:uuid",
        priority: 671,
        level: :admin,
        permission: module_key(),
        parent: :admin_catalogue,
        visible: false,
        live_view: {PhoenixKitCatalogue.Web.CatalogueDetailLive, :show}
      },
      %Tab{
        id: :admin_catalogue_edit,
        label: "Edit Catalogue",
        icon: "hero-pencil-square",
        path: "catalogue/:uuid/edit",
        priority: 672,
        level: :admin,
        permission: module_key(),
        parent: :admin_catalogue,
        visible: false,
        live_view: {PhoenixKitCatalogue.Web.CatalogueFormLive, :edit}
      },
      %Tab{
        id: :admin_catalogue_category_new,
        label: "New Category",
        icon: "hero-plus",
        path: "catalogue/:catalogue_uuid/categories/new",
        priority: 673,
        level: :admin,
        permission: module_key(),
        parent: :admin_catalogue,
        visible: false,
        live_view: {PhoenixKitCatalogue.Web.CategoryFormLive, :new}
      },
      %Tab{
        id: :admin_catalogue_item_new,
        label: "New Item",
        icon: "hero-plus",
        path: "catalogue/:catalogue_uuid/items/new",
        priority: 674,
        level: :admin,
        permission: module_key(),
        parent: :admin_catalogue,
        visible: false,
        live_view: {PhoenixKitCatalogue.Web.ItemFormLive, :new}
      }
    ]
  end
end
