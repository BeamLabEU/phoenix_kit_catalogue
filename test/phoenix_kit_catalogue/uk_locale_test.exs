defmodule PhoenixKitCatalogue.UkLocaleTest do
  @moduledoc """
  Pins the Ukrainian (`uk`) catalogue: complete against `default.pot`,
  no fuzzy or empty entries, resolves through the backend, picks the right
  plural branch, and leaves English untouched.
  """
  use ExUnit.Case, async: true

  alias Expo.Message
  alias Expo.Messages

  @pot_path Path.join(["priv", "gettext", "default.pot"])
  @uk_path Path.join(["priv", "gettext", "uk", "LC_MESSAGES", "default.po"])

  setup do
    previous = Gettext.get_locale(PhoenixKitCatalogue.Gettext)
    on_exit(fn -> Gettext.put_locale(PhoenixKitCatalogue.Gettext, previous) end)
    :ok
  end

  describe "uk catalogue file" do
    test "has exactly the msgids of default.pot" do
      assert File.exists?(@uk_path), "#{@uk_path} is missing"

      pot_ids = msgid_keys(parse!(@pot_path))
      uk_ids = msgid_keys(parse!(@uk_path))

      assert MapSet.size(pot_ids) > 1000
      assert MapSet.to_list(MapSet.difference(pot_ids, uk_ids)) == []
      assert MapSet.to_list(MapSet.difference(uk_ids, pot_ids)) == []
    end

    test "has no empty msgstr and no fuzzy entries" do
      messages = parse!(@uk_path).messages

      empty = for m <- messages, empty_msgstr?(m), do: IO.iodata_to_binary(m.msgid)

      fuzzy =
        for m <- messages, "fuzzy" in List.flatten(m.flags), do: IO.iodata_to_binary(m.msgid)

      assert empty == []
      assert fuzzy == []
    end
  end

  describe "runtime lookup" do
    test "known strings resolve to Ukrainian under the uk locale" do
      for {msgid, uk} <- [
            {"Manual order", "Ручний порядок"},
            {"Export items", "Експорт позицій"},
            {"Catalogue", "Каталог"},
            {"Suppliers", "Постачальники"}
          ] do
        assert gettext_in("uk", msgid) == uk
      end
    end

    test "plural forms pick the right branch for 1 / 2 / 5 / 11 / 21 / 22 / 25" do
      Gettext.put_locale(PhoenixKitCatalogue.Gettext, "uk")

      assert ngettext_item(1) == "1 позиція"
      assert ngettext_item(2) == "2 позиції"
      assert ngettext_item(5) == "5 позицій"
      assert ngettext_item(11) == "11 позицій"
      assert ngettext_item(21) == "21 позиція"
      assert ngettext_item(22) == "22 позиції"
      assert ngettext_item(25) == "25 позицій"
    end

    test "English is unchanged for the same strings (regression guard)" do
      for msgid <- ["Manual order", "Export items", "Catalogue", "Suppliers"] do
        assert gettext_in("en", msgid) == msgid
      end

      Gettext.put_locale(PhoenixKitCatalogue.Gettext, "en")
      assert ngettext_item(1) == "1 item"
      assert ngettext_item(5) == "5 items"
    end
  end

  defp parse!(path) do
    {:ok, po} = Expo.PO.parse_file(path)
    po
  end

  defp msgid_keys(%Messages{messages: messages}), do: MapSet.new(messages, &Message.key/1)

  defp empty_msgstr?(%Message.Singular{msgstr: msgstr}),
    do: IO.iodata_to_binary(msgstr) == ""

  defp empty_msgstr?(%Message.Plural{msgstr: forms}),
    do: Enum.any?(forms, fn {_, s} -> IO.iodata_to_binary(s) == "" end)

  defp gettext_in(locale, msgid) do
    Gettext.put_locale(PhoenixKitCatalogue.Gettext, locale)
    Gettext.gettext(PhoenixKitCatalogue.Gettext, msgid)
  end

  defp ngettext_item(count) do
    Gettext.dngettext(
      PhoenixKitCatalogue.Gettext,
      "default",
      "%{count} item",
      "%{count} items",
      count,
      count: count
    )
  end
end
