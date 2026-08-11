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

  # Regression: "Manual order" and "Clear search and filters to
  # drag-and-drop reorder." were added to the .pot and to the et/ru .po
  # files by hand (the manual-order sort feature isn't picked up by
  # `mix gettext.extract`, same as every other string in this backend),
  # but the en.po entry was forgotten — silently harmless today since
  # gettext falls back to the raw msgid, but a ticking trap if the
  # English source text ever changes without updating en.po too.
  describe "manual-order sort strings are present in every locale" do
    test "Manual order" do
      assert gettext_in("en", "Manual order") == "Manual order"
      assert gettext_in("et", "Manual order") == "Käsitsi järjestus"
      assert gettext_in("ru", "Manual order") == "Ручной порядок"
    end

    test "Clear search and filters to drag-and-drop reorder." do
      msgid = "Clear search and filters to drag-and-drop reorder."
      assert gettext_in("en", msgid) == msgid

      assert gettext_in("et", msgid) ==
               "Tühjenda otsing ja filtrid, et lohistades ümber järjestada."

      assert gettext_in("ru", msgid) ==
               "Очистите поиск и фильтры, чтобы менять порядок перетаскиванием."
    end

    defp gettext_in(locale, msgid) do
      Gettext.put_locale(PhoenixKitCatalogue.Gettext, locale)
      Gettext.gettext(PhoenixKitCatalogue.Gettext, msgid)
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
