defmodule PhoenixKitCatalogue.GettextTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Dashboard.Tab

  setup do
    previous = Gettext.get_locale(PhoenixKitCatalogue.Gettext)
    on_exit(fn -> Gettext.put_locale(PhoenixKitCatalogue.Gettext, previous) end)
    :ok
  end

  test "PhoenixKitCatalogue.Gettext compiles and is a valid gettext backend" do
    assert Code.ensure_loaded?(PhoenixKitCatalogue.Gettext)
  end

  test "Tab.localized_label/1 returns Russian translation for Catalogue" do
    Gettext.put_locale(PhoenixKitCatalogue.Gettext, "ru")

    tab = %Tab{
      id: :admin_catalogue,
      label: "Catalogue",
      gettext_backend: PhoenixKitCatalogue.Gettext,
      gettext_domain: "default"
    }

    assert Tab.localized_label(tab) == "Каталог"
  end

  test "Tab.localized_label/1 returns Estonian translation for Catalogue" do
    Gettext.put_locale(PhoenixKitCatalogue.Gettext, "et")

    tab = %Tab{
      id: :admin_catalogue,
      label: "Catalogue",
      gettext_backend: PhoenixKitCatalogue.Gettext,
      gettext_domain: "default"
    }

    assert Tab.localized_label(tab) == "Kataloog"
  end

  test "Tab.localized_label/1 returns Russian translation for Export" do
    Gettext.put_locale(PhoenixKitCatalogue.Gettext, "ru")

    tab = %Tab{
      id: :admin_catalogue_export,
      label: "Export",
      gettext_backend: PhoenixKitCatalogue.Gettext,
      gettext_domain: "default"
    }

    assert Tab.localized_label(tab) == "Экспорт"
  end

  test "Tab.localized_label/1 returns Estonian translation for Export" do
    Gettext.put_locale(PhoenixKitCatalogue.Gettext, "et")

    tab = %Tab{
      id: :admin_catalogue_export,
      label: "Export",
      gettext_backend: PhoenixKitCatalogue.Gettext,
      gettext_domain: "default"
    }

    assert Tab.localized_label(tab) == "Eksportimine"
  end

  test "Tab.localized_label/1 falls back to raw label when no gettext_backend set" do
    tab = %Tab{
      id: :admin_catalogue,
      label: "Catalogue"
    }

    assert Tab.localized_label(tab) == "Catalogue"
  end

  test "Tab.localized_label/1 falls back to msgid when translation is missing" do
    Gettext.put_locale(PhoenixKitCatalogue.Gettext, "ru")

    tab = %Tab{
      id: :admin_unknown,
      label: "This string has no translation",
      gettext_backend: PhoenixKitCatalogue.Gettext,
      gettext_domain: "default"
    }

    assert Tab.localized_label(tab) == "This string has no translation"
  end

  # Shared by both describe blocks below.
  #
  # The `en` assertions read the parsed .po file directly (`po_msgstr/2`)
  # rather than going through `Gettext.gettext/2` at runtime
  # (`gettext_in/2`): since the English translation text is identical to
  # the msgid, a runtime lookup returns the same string whether or not
  # the entry actually exists (Gettext's documented behavior on a missing
  # translation is to fall back to the raw msgid) — that would make the
  # assertion pass even with the en.po entry deleted entirely, catching
  # nothing.
  defp gettext_in(locale, msgid) do
    Gettext.put_locale(PhoenixKitCatalogue.Gettext, locale)
    Gettext.gettext(PhoenixKitCatalogue.Gettext, msgid)
  end

  # Reads the msgstr for `msgid` straight out of the locale's .po file
  # (nil if the entry is missing), bypassing Gettext's fallback-to-msgid
  # behavior so a deleted/never-added entry actually fails the assertion.
  defp po_msgstr(locale, msgid) do
    path = Path.join(["priv", "gettext", locale, "LC_MESSAGES", "default.po"])
    {:ok, po} = Expo.PO.parse_file(path)

    po.messages
    |> Enum.find(&(IO.iodata_to_binary(&1.msgid) == msgid))
    |> case do
      nil -> nil
      entry -> IO.iodata_to_binary(entry.msgstr)
    end
  end

  # Regression: "Manual order" and "Clear search and filters to
  # drag-and-drop reorder." were added to the .pot and to the et/ru .po
  # files by hand (the manual-order sort feature isn't picked up by
  # `mix gettext.extract`, same as every other string in this backend),
  # but the en.po entry was forgotten — silently harmless today since
  # gettext falls back to the raw msgid, but a ticking trap if the
  # English source text ever changes without updating en.po too.
  describe "manual-order sort strings are present in every locale" do
    test "Manual order" do
      assert po_msgstr("en", "Manual order") == "Manual order"
      assert gettext_in("et", "Manual order") == "Käsitsi järjestus"
      assert gettext_in("ru", "Manual order") == "Ручной порядок"
    end

    test "Clear search and filters to drag-and-drop reorder." do
      msgid = "Clear search and filters to drag-and-drop reorder."
      assert po_msgstr("en", msgid) == msgid

      assert gettext_in("et", msgid) ==
               "Tühjenda otsing ja filtrid, et lohistades ümber järjestada."

      assert gettext_in("ru", msgid) ==
               "Очистите поиск и фильтры, чтобы менять порядок перетаскиванием."
    end
  end

  # Regression: "Export Items" (export_live.ex) had en/ru entries but the
  # et entry was missing, and nothing exercised it — deleting the et entry
  # left the whole suite green. Also covers the four Export-page strings
  # (Destination, Format, "Select a format...", "Add the catalogue name to
  # the item name") that were never added to any locale at all, leaving a
  # Russian or Estonian admin four raw English strings on that page.
  # "Format" and "Select a format..." are shared with the Import page.
  describe "Export tab strings are present in every locale" do
    test "Export Items" do
      assert po_msgstr("en", "Export Items") == "Export Items"
      assert gettext_in("et", "Export Items") == "Ekspordi tooteid"
      assert gettext_in("ru", "Export Items") == "Экспорт позиций"
    end

    test "Destination" do
      assert po_msgstr("en", "Destination") == "Destination"
      assert gettext_in("et", "Destination") == "Sihtkoht"
      assert gettext_in("ru", "Destination") == "Назначение"
    end

    test "Format" do
      assert po_msgstr("en", "Format") == "Format"
      assert gettext_in("et", "Format") == "Formaat"
      assert gettext_in("ru", "Format") == "Формат"
    end

    test "Select a format..." do
      msgid = "Select a format..."
      assert po_msgstr("en", msgid) == msgid
      assert gettext_in("et", msgid) == "Vali formaat..."
      assert gettext_in("ru", msgid) == "Выберите формат..."
    end

    test "Add the catalogue name to the item name" do
      msgid = "Add the catalogue name to the item name"
      assert po_msgstr("en", msgid) == msgid
      assert gettext_in("et", msgid) == "Lisa kataloogi nimi toote nimele"
      assert gettext_in("ru", msgid) == "Добавить название каталога к названию позиции"
    end
  end

  # The featured-image picker names its purpose in the modal heading instead
  # of core's generic "Select Media"; the msgid lives in all three form
  # LiveViews' MediaSelectorModal embeds (catalogue / category / item).
  describe "Media picker strings are present in every locale" do
    test "Select Featured Image" do
      msgid = "Select Featured Image"
      assert po_msgstr("en", msgid) == msgid
      assert gettext_in("et", msgid) == "Vali põhipilt"
      assert gettext_in("ru", msgid) == "Выбрать главное изображение"
    end
  end

  describe "product card strings are present in every locale" do
    test "View item details" do
      assert po_msgstr("en", "View item details") == "View item details"
      assert gettext_in("et", "View item details") == "Vaata toote kaarti"
      assert gettext_in("ru", "View item details") == "Показать карточку товара"
    end

    test "Show this image" do
      assert po_msgstr("en", "Show this image") == "Show this image"
      assert gettext_in("et", "Show this image") == "Näita seda pilti"
      assert gettext_in("ru", "Show this image") == "Показать это изображение"
    end

    test "Close" do
      assert po_msgstr("en", "Close") == "Close"
      assert gettext_in("et", "Close") == "Sulge"
      assert gettext_in("ru", "Close") == "Закрыть"
    end

    test "Open" do
      assert po_msgstr("en", "Open") == "Open"
      assert gettext_in("et", "Open") == "Ava"
      assert gettext_in("ru", "Open") == "Открыть"
    end

    test "Hide" do
      assert po_msgstr("en", "Hide") == "Hide"
      assert gettext_in("et", "Hide") == "Peida"
      assert gettext_in("ru", "Hide") == "Скрыть"
    end
  end

  describe "ngettext plural selection" do
    test "Russian 3-form rules pick the right msgstr for 1 / 2 / 5 / 21 / 22" do
      Gettext.put_locale(PhoenixKitCatalogue.Gettext, "ru")

      assert ngettext_item(1) == "1 позиция"
      assert ngettext_item(2) == "2 позиции"
      assert ngettext_item(5) == "5 позиций"
      assert ngettext_item(21) == "21 позиция"
      assert ngettext_item(22) == "22 позиции"
    end

    test "Estonian 2-form rules pick singular for 1, plural otherwise" do
      Gettext.put_locale(PhoenixKitCatalogue.Gettext, "et")

      assert ngettext_item(1) == "1 toode"
      assert ngettext_item(2) == "2 toodet"
      assert ngettext_item(5) == "5 toodet"
    end

    test "English passthrough" do
      Gettext.put_locale(PhoenixKitCatalogue.Gettext, "en")

      assert ngettext_item(1) == "1 item"
      assert ngettext_item(5) == "5 items"
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
end
