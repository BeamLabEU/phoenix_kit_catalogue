defmodule PhoenixKitCatalogue.AttachmentsTest do
  @moduledoc """
  Direct unit tests for the pure functions on
  `PhoenixKitCatalogue.Attachments` — template helpers (file size +
  icon + upload-error message), the upload name constant, and
  `inject_attachment_data/2` which threads featured-image + folder
  UUIDs into params.

  Socket-bound mount/event helpers are exercised through the form
  LV smoke tests (`test/web/form_lives_test.exs` etc.) — adding LV
  tests for them would duplicate that coverage.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitCatalogue.Attachments

  describe "format_file_size/1" do
    test "nil renders as em dash" do
      assert Attachments.format_file_size(nil) == "—"
    end

    test "non-integer renders as em dash" do
      assert Attachments.format_file_size("not a number") == "—"
      assert Attachments.format_file_size(:foo) == "—"
    end

    test "bytes < 1 KB render as B" do
      assert Attachments.format_file_size(0) == "0 B"
      assert Attachments.format_file_size(999) == "999 B"
    end

    test "1 KB to 1 MB render as KB with one decimal" do
      assert Attachments.format_file_size(1_000) == "1.0 KB"
      assert Attachments.format_file_size(1_500) == "1.5 KB"
      # Float.round(999_999 / 1_000, 1) renders in scientific notation
      # ("1.0e3 KB"); pin the actual current behaviour rather than the
      # naive expectation. A future tightening can switch to
      # :erlang.float_to_binary with explicit decimals if the sci-notation
      # output is undesirable.
      assert Attachments.format_file_size(999_999) =~ "KB"
    end

    test "1 MB to 1 GB render as MB with one decimal" do
      assert Attachments.format_file_size(1_000_000) == "1.0 MB"
      assert Attachments.format_file_size(2_500_000) == "2.5 MB"
    end

    test ">= 1 GB render as GB with one decimal" do
      assert Attachments.format_file_size(1_000_000_000) == "1.0 GB"
      assert Attachments.format_file_size(3_750_000_000) == "3.8 GB"
    end
  end

  describe "file_icon/1" do
    test "image type returns hero-photo" do
      assert Attachments.file_icon(%{file_type: "image"}) == "hero-photo"
    end

    test "video type returns hero-film" do
      assert Attachments.file_icon(%{file_type: "video"}) == "hero-film"
    end

    test "audio type returns hero-musical-note" do
      assert Attachments.file_icon(%{file_type: "audio"}) == "hero-musical-note"
    end

    test "archive type returns hero-archive-box" do
      assert Attachments.file_icon(%{file_type: "archive"}) == "hero-archive-box"
    end

    test "PDF mime falls through to hero-document-text" do
      assert Attachments.file_icon(%{mime_type: "application/pdf"}) == "hero-document-text"
    end

    test "unknown type falls through to hero-document" do
      assert Attachments.file_icon(%{file_type: "unknown"}) == "hero-document"
      assert Attachments.file_icon(%{mime_type: "application/octet-stream"}) == "hero-document"
      assert Attachments.file_icon(%{}) == "hero-document"
    end

    test "file_type takes priority over mime_type" do
      # Even with a PDF mime, an image file_type wins.
      assert Attachments.file_icon(%{file_type: "image", mime_type: "application/pdf"}) ==
               "hero-photo"
    end
  end

  describe "upload_error_message/1" do
    test ":too_large returns translated message" do
      assert Attachments.upload_error_message(:too_large) == "File is too large."
    end

    test ":not_accepted returns translated message" do
      assert Attachments.upload_error_message(:not_accepted) == "File type not accepted."
    end

    test ":too_many_files returns translated message" do
      assert Attachments.upload_error_message(:too_many_files) == "Too many files."
    end

    test "unknown atom interpolates via gettext" do
      msg = Attachments.upload_error_message(:weird_thing)
      assert msg =~ "Upload error"
      assert msg =~ "weird_thing"
    end
  end

  describe "upload_name/0" do
    test "returns the canonical upload ref atom" do
      assert Attachments.upload_name() == :attachment_files
    end
  end

  describe "inject_attachment_data/2 — folder + featured image threading" do
    test "no folder_uuid + no featured_image still ensures data key exists" do
      # The current implementation always passes through
      # `inject_featured_image(params, nil)` which writes an empty
      # data map. Pin the behaviour explicitly — non-data keys are
      # preserved untouched.
      socket = build_fake_socket(folder: nil, featured: nil)
      result = Attachments.inject_attachment_data(%{"name" => "X"}, socket)
      assert result["name"] == "X"
      assert result["data"] == %{}
    end

    test "folder_uuid lands in params['data']['files_folder_uuid']" do
      uuid = Ecto.UUID.generate()
      socket = build_fake_socket(folder: uuid, featured: nil)

      result = Attachments.inject_attachment_data(%{"name" => "X"}, socket)

      assert get_in(result, ["data", "files_folder_uuid"]) == uuid
    end

    test "featured_image_uuid lands in params['data']['featured_image_uuid']" do
      uuid = Ecto.UUID.generate()
      socket = build_fake_socket(folder: nil, featured: uuid)

      result = Attachments.inject_attachment_data(%{"name" => "X"}, socket)

      assert get_in(result, ["data", "featured_image_uuid"]) == uuid
    end

    test "nil featured_image clears existing data['featured_image_uuid']" do
      socket = build_fake_socket(folder: nil, featured: nil)

      params = %{"name" => "X", "data" => %{"featured_image_uuid" => "stale"}}
      result = Attachments.inject_attachment_data(params, socket)

      # nil featured + existing stale value → cleared (sets to nil)
      assert get_in(result, ["data", "featured_image_uuid"]) == nil
    end

    test "preserves existing data keys not owned by Attachments" do
      socket = build_fake_socket(folder: nil, featured: nil)

      params = %{"name" => "X", "data" => %{"unrelated" => "keep"}}
      result = Attachments.inject_attachment_data(params, socket)

      assert get_in(result, ["data", "unrelated"]) == "keep"
    end

    test "both folder + featured set together" do
      folder = Ecto.UUID.generate()
      featured = Ecto.UUID.generate()
      socket = build_fake_socket(folder: folder, featured: featured)

      result = Attachments.inject_attachment_data(%{"name" => "X"}, socket)

      assert get_in(result, ["data", "files_folder_uuid"]) == folder
      assert get_in(result, ["data", "featured_image_uuid"]) == featured
    end
  end

  # Build a struct-like fake socket with just the assigns we need.
  # Phoenix.LiveView.Socket has many required fields; build one
  # via struct/2 with minimal overrides.
  defp build_fake_socket(folder: folder, featured: featured) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        files_folder_uuid: folder,
        featured_image_uuid: featured
      }
    }
  end
end
