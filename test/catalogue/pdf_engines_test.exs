defmodule PhoenixKitCatalogue.Catalogue.PdfEnginesTest do
  @moduledoc """
  The extraction engine chain. Pins:

  - `open_best/1` opens a real (minimal, generated) PDF with the pdfium
    engine and `extract_page/2` returns its text — the whole no-system-
    packages path, exercising the actual NIF.
  - garbage input walks the whole chain and reports every engine's
    refusal reason.
  - `parse_page_count/1` (poppler's `pdfinfo` output parser) — moved
    here from the worker with the engine split.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitCatalogue.Catalogue.PdfEngines

  # Builds a valid single-page PDF with `text` drawn in Helvetica.
  # Offsets in the xref table are computed, not hardcoded, so the
  # fixture can't rot.
  defp minimal_pdf(text) do
    content = "BT /F1 12 Tf 72 720 Td (#{text}) Tj ET"

    objects = [
      "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
      "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
      "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " <>
        "/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>\nendobj\n",
      "4 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n",
      "5 0 obj\n<< /Length #{byte_size(content)} >>\nstream\n#{content}\nendstream\nendobj\n"
    ]

    header = "%PDF-1.4\n"

    {body, offsets} =
      Enum.reduce(objects, {header, []}, fn obj, {acc, offs} ->
        {acc <> obj, offs ++ [byte_size(acc)]}
      end)

    xref_offset = byte_size(body)

    xref =
      "xref\n0 6\n0000000000 65535 f \n" <>
        Enum.map_join(offsets, "", fn off ->
          String.pad_leading(Integer.to_string(off), 10, "0") <> " 00000 n \n"
        end)

    trailer =
      "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n#{xref_offset}\n%%EOF\n"

    body <> xref <> trailer
  end

  defp write_fixture(text) do
    path =
      Path.join(
        System.tmp_dir!(),
        "pk_cat_engine_fixture_#{System.unique_integer([:positive])}.pdf"
      )

    File.write!(path, minimal_pdf(text))
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "open_best/1 + extract_page/2" do
    test "extracts text from a real PDF via the pdfium engine" do
      path = write_fixture("Hello PDF Engines")

      assert {:ok, engine} = PdfEngines.open_best(path)
      assert engine.name == "pdfium"
      assert engine.page_count == 1

      assert {:ok, text} = PdfEngines.extract_page(engine, 1)
      assert text =~ "Hello PDF Engines"
    end

    test "a non-PDF walks the chain and reports every engine's reason" do
      path =
        Path.join(
          System.tmp_dir!(),
          "pk_cat_engine_garbage_#{System.unique_integer([:positive])}"
        )

      File.write!(path, "this is not a pdf at all")
      on_exit(fn -> File.rm(path) end)

      assert {:error, attempts} = PdfEngines.open_best(path)
      names = Enum.map(attempts, &elem(&1, 0))
      assert "pdfium" in names
      assert "poppler" in names
    end
  end

  describe "parse_page_count/1" do
    test "extracts integer from a typical pdfinfo line" do
      output = "Title: x\nPages:          12\nEncrypted: no\n"
      assert {:ok, 12} = PdfEngines.parse_page_count(output)
    end

    test "accepts page counts of 1 and 0 (degenerate but legal)" do
      assert {:ok, 1} = PdfEngines.parse_page_count("Pages:  1\n")
      assert {:ok, 0} = PdfEngines.parse_page_count("Pages:  0\n")
    end

    test "returns error when no Pages line" do
      assert {:error, {:pdfinfo_failed, _}} = PdfEngines.parse_page_count("garbage output")
      assert {:error, {:pdfinfo_failed, _}} = PdfEngines.parse_page_count("")
    end

    test "ignores Pages: hidden inside other lines (^ anchor pin)" do
      assert {:error, {:pdfinfo_failed, _}} =
               PdfEngines.parse_page_count("Some Pages: 999 are mentioned in body\n")
    end
  end
end
