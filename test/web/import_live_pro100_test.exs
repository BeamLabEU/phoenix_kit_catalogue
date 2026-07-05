defmodule PhoenixKitCatalogue.Web.ImportLivePro100Test do
  @moduledoc """
  Integration tests for the PRO100 sync flow wired into ImportLive.
  Covers source/format selects, the :preview step, apply_pro100 handler,
  and the :report step.
  """

  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue

  @import_url "/en/admin/catalogue/import"

  # Minimal valid PRO100 furniture file with one data row.
  # Header: "# Parts\t<col_names>"
  # Data: "\t\tname\tid\tc3\tprice\tc5\tc6\tc7"
  defp furniture_file(rows) do
    header = "# Parts\tname\tid\tc3\tprice\tc5\tc6\tc7"
    data = Enum.map(rows, fn {name, id, price} -> "\t\t#{name}\t#{id}\t\t#{price}\t\t\t" end)
    Enum.join([header | data], "\n")
  end

  defp build_file_input(view, filename, content_type, contents) do
    Phoenix.LiveViewTest.file_input(view, "#upload-form", :import_file, [
      %{
        last_modified: 1_700_000_000_000,
        name: filename,
        content: contents,
        type: content_type
      }
    ])
  end

  setup do
    cat = fixture_catalogue(%{name: "PRO100 Test Cat"})

    item =
      fixture_item(%{
        name: "Chair Alpha",
        sku: "W-9",
        base_price: "99.00",
        catalogue_uuid: cat.uuid
      })

    %{catalogue: cat, item: item}
  end

  describe "upload_step renders source/format selects" do
    test "upload page shows source select", %{conn: conn} do
      {:ok, _view, html} = live(conn, @import_url)
      assert html =~ "Source"
      assert html =~ "upload-source"
    end
  end

  describe "validate_upload sets selected_source and selected_format" do
    test "selecting pro100 source updates assigns", %{conn: conn, catalogue: cat} do
      {:ok, view, _html} = live(conn, @import_url)
      render_change(view, "validate_upload", %{"catalogue" => cat.uuid, "source" => "pro100"})
      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.selected_source == "pro100"
      assert assigns.selected_format == nil
    end

    test "selecting source + format updates both assigns", %{conn: conn, catalogue: cat} do
      {:ok, view, _html} = live(conn, @import_url)

      render_change(view, "validate_upload", %{
        "catalogue" => cat.uuid,
        "source" => "pro100",
        "format" => "furniture"
      })

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.selected_source == "pro100"
      assert assigns.selected_format == "furniture"
    end

    test "changing source resets format", %{conn: conn, catalogue: cat} do
      {:ok, view, _html} = live(conn, @import_url)

      # First pick pro100 + furniture
      render_change(view, "validate_upload", %{
        "catalogue" => cat.uuid,
        "source" => "pro100",
        "format" => "furniture"
      })

      # Then switch to universal — format must reset
      render_change(view, "validate_upload", %{
        "catalogue" => cat.uuid,
        "source" => "universal"
      })

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.selected_source == "universal"
      assert assigns.selected_format == nil
    end
  end

  describe "PRO100 sync flow — happy path" do
    test "uploads furniture file and transitions to :preview step",
         %{conn: conn, catalogue: cat, item: item} do
      {:ok, view, _html} = live(conn, @import_url)

      render_change(view, "validate_upload", %{
        "catalogue" => cat.uuid,
        "source" => "pro100",
        "format" => "furniture"
      })

      # The item SKU is "W-9" → digits_id "9". Use "9" as the id in the file.
      txt = furniture_file([{item.name, "9", "150.00"}])
      file = build_file_input(view, "export.txt", "text/plain", txt)
      render_upload(file, "export.txt")

      render_submit(view, "parse_file", %{
        "catalogue" => cat.uuid,
        "source" => "pro100",
        "format" => "furniture"
      })

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.step == :preview
      assert assigns.import_plan != nil
      assert assigns.import_plan.updates != []
    end

    test "apply_pro100 persists price update and transitions to :report",
         %{conn: conn, catalogue: cat, item: item} do
      {:ok, view, _html} = live(conn, @import_url)

      render_change(view, "validate_upload", %{
        "catalogue" => cat.uuid,
        "source" => "pro100",
        "format" => "furniture"
      })

      txt = furniture_file([{item.name, "9", "250.00"}])
      file = build_file_input(view, "export.txt", "text/plain", txt)
      render_upload(file, "export.txt")

      render_submit(view, "parse_file", %{
        "catalogue" => cat.uuid,
        "source" => "pro100",
        "format" => "furniture"
      })

      render_click(view, "apply_pro100", %{})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.step == :report
      assert assigns.report != nil
      assert assigns.report.updated >= 1

      # Verify the DB item was actually updated
      updated_item = Catalogue.get_item!(item.uuid)
      assert Decimal.equal?(updated_item.base_price, Decimal.new("250.00"))
    end
  end

  describe "PRO100 sync flow — guard branches" do
    test "parse_file without format selected flashes error",
         %{conn: conn, catalogue: cat, item: item} do
      {:ok, view, _html} = live(conn, @import_url)

      render_change(view, "validate_upload", %{
        "catalogue" => cat.uuid,
        "source" => "pro100"
        # no format
      })

      txt = furniture_file([{item.name, "9", "100.00"}])
      file = build_file_input(view, "export.txt", "text/plain", txt)
      render_upload(file, "export.txt")

      html = render_submit(view, "parse_file", %{"catalogue" => cat.uuid, "source" => "pro100"})

      assert html =~ "Please select a format"
      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.step == :upload
    end

    test "parse_file with bad PRO100 content flashes error",
         %{conn: conn, catalogue: cat} do
      {:ok, view, _html} = live(conn, @import_url)

      render_change(view, "validate_upload", %{
        "catalogue" => cat.uuid,
        "source" => "pro100",
        "format" => "furniture"
      })

      file = build_file_input(view, "bad.txt", "text/plain", "not a pro100 file\n")
      render_upload(file, "bad.txt")

      html =
        render_submit(view, "parse_file", %{
          "catalogue" => cat.uuid,
          "source" => "pro100",
          "format" => "furniture"
        })

      assert html =~ "format"
      assert :sys.get_state(view.pid).socket.assigns.step == :upload
    end
  end

  describe "import_another resets to upload step" do
    test "after :report, import_another resets source/format and returns to :upload",
         %{conn: conn, catalogue: cat, item: item} do
      {:ok, view, _html} = live(conn, @import_url)

      render_change(view, "validate_upload", %{
        "catalogue" => cat.uuid,
        "source" => "pro100",
        "format" => "furniture"
      })

      txt = furniture_file([{item.name, "9", "55.00"}])
      file = build_file_input(view, "export.txt", "text/plain", txt)
      render_upload(file, "export.txt")

      render_submit(view, "parse_file", %{
        "catalogue" => cat.uuid,
        "source" => "pro100",
        "format" => "furniture"
      })

      render_click(view, "apply_pro100", %{})
      render_click(view, "import_another", %{})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.step == :upload
      assert assigns.selected_source == "universal"
      assert assigns.selected_format == nil
      assert assigns.report == nil
      assert assigns.import_plan == nil
    end
  end
end
