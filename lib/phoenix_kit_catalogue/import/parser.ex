NimbleCSV.define(PhoenixKitCatalogue.Import.CommaParser, separator: ",", escape: "\"")
NimbleCSV.define(PhoenixKitCatalogue.Import.SemicolonParser, separator: ";", escape: "\"")
NimbleCSV.define(PhoenixKitCatalogue.Import.TabParser, separator: "\t", escape: "\"")

defmodule PhoenixKitCatalogue.Import.Parser do
  @moduledoc """
  Parses XLSX and CSV files into structured row data.

  Returns a map with headers, rows, sheet names, and row count.
  Uses no external dependencies beyond what phoenix_kit already provides:
  - NimbleCSV for CSV (auto-detects separator)
  - XlsxReader for XLSX
  """

  alias PhoenixKitCatalogue.Import.{CommaParser, SemicolonParser, TabParser}

  @type parsed_file :: %{
          sheets: [String.t()],
          headers: [String.t()],
          rows: [[String.t()]],
          row_count: non_neg_integer()
        }

  @doc """
  Detects file format from the filename extension.
  """
  @spec detect_format(String.t()) :: :xlsx | :csv | {:error, :unsupported}
  def detect_format(filename) do
    case filename |> String.downcase() |> Path.extname() do
      ".xlsx" -> :xlsx
      ".csv" -> :csv
      ".tsv" -> :csv
      _ -> {:error, :unsupported}
    end
  end

  @doc """
  Parses a file binary into structured data.

  ## Options

    * `:sheet` — sheet name to parse (XLSX only, defaults to first sheet)
  """
  @spec parse(binary(), String.t(), keyword()) :: {:ok, parsed_file()} | {:error, String.t()}
  def parse(binary, filename, opts \\ []) do
    case detect_format(filename) do
      :xlsx -> parse_xlsx(binary, opts)
      :csv -> parse_csv(binary)
      {:error, :unsupported} -> {:error, "Unsupported file format. Please upload .xlsx or .csv"}
    end
  end

  @doc """
  Lists sheet names from an XLSX file.
  """
  @spec list_sheets(binary()) :: {:ok, [String.t()]} | {:error, String.t()}
  def list_sheets(binary) do
    with_temp_file(binary, ".xlsx", fn path ->
      case XlsxReader.open(path) do
        {:ok, package} ->
          {:ok, XlsxReader.sheet_names(package)}

        {:error, reason} ->
          {:error, "Failed to read XLSX: #{inspect(reason)}"}
      end
    end)
  end

  # ── XLSX Parsing ──────────────────────────────────────────────

  defp parse_xlsx(binary, opts) do
    sheet_name = Keyword.get(opts, :sheet)

    with_temp_file(binary, ".xlsx", fn path ->
      case XlsxReader.open(path) do
        {:ok, package} ->
          sheets = XlsxReader.sheet_names(package)
          target_sheet = sheet_name || List.first(sheets)
          read_xlsx_sheet(package, target_sheet, sheets)

        {:error, reason} ->
          {:error, "Failed to open XLSX: #{inspect(reason)}"}
      end
    end)
  end

  defp read_xlsx_sheet(package, target_sheet, sheets) do
    case XlsxReader.sheet(package, target_sheet, empty_rows: false) do
      {:ok, []} ->
        {:error, "Sheet '#{target_sheet}' is empty"}

      {:ok, [header_row | data_rows]} ->
        headers = Enum.map(header_row, &to_string/1)

        rows =
          data_rows |> Enum.map(fn row -> Enum.map(row, &to_string/1) end) |> reject_empty_rows()

        {:ok, %{sheets: sheets, headers: headers, rows: rows, row_count: length(rows)}}

      {:error, reason} ->
        {:error, "Failed to read sheet '#{target_sheet}': #{inspect(reason)}"}
    end
  end

  defp with_temp_file(binary, ext, fun) do
    tmp_path = Path.join(System.tmp_dir!(), "import_#{:erlang.unique_integer([:positive])}#{ext}")

    try do
      File.write!(tmp_path, binary)
      fun.(tmp_path)
    after
      File.rm(tmp_path)
    end
  end

  # ── CSV Parsing ───────────────────────────────────────────────

  defp parse_csv(binary) do
    binary = strip_bom(binary)

    parser = detect_csv_separator(binary)

    try do
      all_rows = parser.parse_string(binary, skip_headers: false)

      case all_rows do
        [] ->
          {:error, "CSV file is empty"}

        [header_row | data_rows] ->
          headers = Enum.map(header_row, &String.trim/1)
          rows = Enum.map(data_rows, fn row -> Enum.map(row, &String.trim/1) end)
          rows = reject_empty_rows(rows)

          {:ok,
           %{
             sheets: ["Sheet1"],
             headers: headers,
             rows: rows,
             row_count: length(rows)
           }}
      end
    rescue
      e ->
        {:error, "Failed to parse CSV: #{Exception.message(e)}"}
    end
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(binary), do: binary

  defp detect_csv_separator(binary) do
    first_line = binary |> String.split(~r/\r?\n/, parts: 2) |> List.first("")

    comma_count = first_line |> String.graphemes() |> Enum.count(&(&1 == ","))
    semicolon_count = first_line |> String.graphemes() |> Enum.count(&(&1 == ";"))
    tab_count = first_line |> String.graphemes() |> Enum.count(&(&1 == "\t"))

    cond do
      tab_count > comma_count and tab_count > semicolon_count -> TabParser
      semicolon_count > comma_count -> SemicolonParser
      comma_count > 0 -> CommaParser
      semicolon_count > 0 -> SemicolonParser
      true -> CommaParser
    end
  end

  # ── Helpers ───────────────────────────────────────────────────

  defp reject_empty_rows(rows) do
    Enum.reject(rows, fn row ->
      Enum.all?(row, fn cell -> cell == "" or is_nil(cell) end)
    end)
  end
end
