defmodule PhoenixKitCatalogue.LiveCase do
  @moduledoc """
  Test case for LiveView tests. Wires up the test Endpoint, imports
  `Phoenix.LiveViewTest` helpers, and sets up an Ecto SQL sandbox
  connection.

  Tests using this case are tagged `:integration` automatically and
  get excluded when the test DB isn't available, matching the rest of
  the suite.

  ## Example

      defmodule PhoenixKitCatalogue.Web.CatalogueFormLiveTest do
        use PhoenixKitCatalogue.LiveCase

        test "renders", %{conn: conn} do
          {:ok, view, html} = live(conn, ~p"/admin/catalogue/new")
          assert html =~ "New Catalogue"
        end
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration
      @endpoint PhoenixKitCatalogue.Test.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import PhoenixKitCatalogue.LiveCase
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitCatalogue.Test.Repo, as: TestRepo

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})

    {:ok, conn: conn}
  end

  @doc """
  Shortcut: insert a minimal catalogue for tests that just need a
  container and don't care about the exact markup percentage.
  """
  def fixture_catalogue(attrs \\ %{}) do
    {:ok, catalogue} =
      PhoenixKitCatalogue.Catalogue.create_catalogue(
        Map.merge(%{name: "Test Catalogue #{System.unique_integer([:positive])}"}, attrs)
      )

    catalogue
  end

  def fixture_category(catalogue, attrs \\ %{}) do
    {:ok, category} =
      PhoenixKitCatalogue.Catalogue.create_category(
        Map.merge(
          %{
            name: "Test Category #{System.unique_integer([:positive])}",
            catalogue_uuid: catalogue.uuid
          },
          attrs
        )
      )

    category
  end

  def fixture_item(attrs \\ %{}) do
    attrs = ensure_item_catalogue(attrs)

    {:ok, item} =
      PhoenixKitCatalogue.Catalogue.create_item(
        Map.merge(%{name: "Test Item #{System.unique_integer([:positive])}"}, attrs)
      )

    item
  end

  def fixture_manufacturer(attrs \\ %{}) do
    {:ok, manufacturer} =
      PhoenixKitCatalogue.Catalogue.create_manufacturer(
        Map.merge(%{name: "Test Manufacturer #{System.unique_integer([:positive])}"}, attrs)
      )

    manufacturer
  end

  def fixture_supplier(attrs \\ %{}) do
    {:ok, supplier} =
      PhoenixKitCatalogue.Catalogue.create_supplier(
        Map.merge(%{name: "Test Supplier #{System.unique_integer([:positive])}"}, attrs)
      )

    supplier
  end

  defp ensure_item_catalogue(attrs) do
    cond do
      Map.has_key?(attrs, :catalogue_uuid) -> attrs
      Map.has_key?(attrs, :category_uuid) -> attrs
      true -> Map.put(attrs, :catalogue_uuid, fixture_catalogue().uuid)
    end
  end
end
