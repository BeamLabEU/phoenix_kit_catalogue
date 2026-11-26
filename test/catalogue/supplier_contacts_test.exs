defmodule PhoenixKitCatalogue.Catalogue.SupplierContactsTest do
  @moduledoc """
  Supplier contacts through the context: the replace-all setter and how it
  settles primaries, the `contact_info` summary it keeps, the legacy path
  (`create_supplier` / `update_supplier` writing `contact_info`) going
  through the same setter, the V8 backfill, and the resolve maps picking
  up email and phone.
  """

  use PhoenixKitCatalogue.DataCase, async: false

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Migrations
  alias PhoenixKitCatalogue.Schemas.{Supplier, SupplierContact}

  defp supplier(attrs \\ %{}) do
    {:ok, s} = Catalogue.create_supplier(Map.merge(%{name: "Kraana OÜ"}, attrs))
    s
  end

  defp stored(s), do: Repo.get!(Supplier, s.uuid)

  defp summary(contacts),
    do: Enum.map(contacts, &{&1.kind, &1.value, &1.is_primary})

  describe "SupplierContact.classify/1" do
    test "guesses email, url, phone and otherwise other" do
      assert SupplierContact.classify("sales@kraana.ee") == "email"
      assert SupplierContact.classify(" https://kraana.ee ") == "url"
      assert SupplierContact.classify("www.kraana.ee") == "url"
      assert SupplierContact.classify("+372 5555 1234") == "phone"
      assert SupplierContact.classify("(06) 123-456") == "phone"
      assert SupplierContact.classify("Mari, +372 5555 1234") == "other"
      assert SupplierContact.classify("ask for Mari") == "other"
    end
  end

  describe "put_supplier_contacts/3" do
    test "stores the list in order and writes the summary of the primaries" do
      s = supplier()

      {:ok, updated} =
        Catalogue.put_supplier_contacts(s, [
          %{kind: "email", value: "sales@kraana.ee", label: "Sales"},
          %{"kind" => "phone", "value" => "+372 5555 1234"},
          %{kind: "person", value: "Mari Maasikas"},
          %{kind: "email", value: "night@kraana.ee"}
        ])

      assert summary(updated.contacts) == [
               {"email", "sales@kraana.ee", true},
               {"phone", "+372 5555 1234", true},
               {"person", "Mari Maasikas", true},
               {"email", "night@kraana.ee", false}
             ]

      # Kind order, not list order: person, phone, email.
      assert updated.contact_info == "Mari Maasikas, +372 5555 1234, sales@kraana.ee"
      assert stored(s).contact_info == updated.contact_info
      assert hd(updated.contacts).label == "Sales"
    end

    test "the first flagged contact of a kind wins; an unflagged kind gets its first" do
      s = supplier()

      {:ok, updated} =
        Catalogue.put_supplier_contacts(s, [
          %{kind: "email", value: "a@kraana.ee"},
          %{kind: "email", value: "b@kraana.ee", is_primary: true},
          %{kind: "email", value: "c@kraana.ee", is_primary: true}
        ])

      assert summary(updated.contacts) == [
               {"email", "a@kraana.ee", false},
               {"email", "b@kraana.ee", true},
               {"email", "c@kraana.ee", false}
             ]

      assert updated.contact_info == "b@kraana.ee"
    end

    test "an invalid contact writes nothing" do
      s = supplier(%{contact_info: "old text"})

      assert {:error, %Ecto.Changeset{} = cs} =
               Catalogue.put_supplier_contacts(s, [
                 %{kind: "phone", value: "+372 1"},
                 %{kind: "email", value: "not an email"}
               ])

      assert errors_on(cs)[:value]
      assert {:error, cs} = Catalogue.put_supplier_contacts(s, [%{kind: "fax", value: "1"}])
      assert errors_on(cs)[:kind]

      assert summary(Catalogue.list_supplier_contacts(s)) == [{"other", "old text", true}]
      assert stored(s).contact_info == "old text"
    end

    test "an empty list clears contact_info" do
      s = supplier(%{contact_info: "sales@kraana.ee"})
      {:ok, updated} = Catalogue.put_supplier_contacts(s, [])
      assert updated.contacts == []
      assert stored(s).contact_info == nil
    end

    test "an unchanged list writes and logs nothing" do
      s = supplier()
      specs = [%{kind: "phone", value: "+372 5555 1234"}]
      {:ok, first} = Catalogue.put_supplier_contacts(s, specs)
      [contact] = first.contacts

      {:ok, again} = Catalogue.put_supplier_contacts(s, specs)
      assert [%{uuid: uuid}] = again.contacts
      assert uuid == contact.uuid
    end

    test "add, set primary and delete go through the same setter" do
      s = supplier()
      {:ok, s1} = Catalogue.add_supplier_contact(s, %{kind: "phone", value: "+372 5555 0001"})
      {:ok, s2} = Catalogue.add_supplier_contact(s1, %{kind: "phone", value: "+372 5555 0002"})
      assert s2.contact_info == "+372 5555 0001"

      second = Enum.find(s2.contacts, &(&1.value == "+372 5555 0002"))
      {:ok, s3} = Catalogue.set_primary_supplier_contact(s2, second.uuid)
      assert s3.contact_info == "+372 5555 0002"

      {:ok, s4} =
        Catalogue.add_supplier_contact(s3, %{
          kind: "phone",
          value: "+372 5555 0003",
          is_primary: true
        })

      assert s4.contact_info == "+372 5555 0003"
      assert Enum.count(s4.contacts, & &1.is_primary) == 1

      primary = Enum.find(s4.contacts, & &1.is_primary)
      {:ok, s5} = Catalogue.delete_supplier_contact(s4, primary.uuid)
      # The next phone takes over.
      assert s5.contact_info == "+372 5555 0001"

      assert {:error, :not_found} =
               Catalogue.set_primary_supplier_contact(s5, Ecto.UUID.generate())
    end

    test "the database refuses a second primary of a kind" do
      s = supplier()

      {:ok, _} =
        %SupplierContact{}
        |> SupplierContact.changeset(%{
          supplier_uuid: s.uuid,
          kind: "email",
          value: "a@b.ee",
          is_primary: true
        })
        |> Repo.insert()

      assert {:error, cs} =
               %SupplierContact{}
               |> SupplierContact.changeset(%{
                 supplier_uuid: s.uuid,
                 kind: "email",
                 value: "c@d.ee",
                 is_primary: true
               })
               |> Repo.insert()

      assert errors_on(cs)[:is_primary]
    end

    test "a hard delete of the supplier takes its contacts" do
      s = supplier(%{contact_info: "sales@kraana.ee"})
      assert [_] = Catalogue.list_supplier_contacts(s)
      {:ok, _} = Catalogue.delete_supplier(s)
      assert Repo.aggregate(SupplierContact, :count) == 0
    end
  end

  describe "the legacy contact_info path" do
    test "create_supplier with contact_info makes it the primary of its kind" do
      s = supplier(%{contact_info: "sales@kraana.ee"})
      assert s.contact_info == "sales@kraana.ee"
      assert summary(Catalogue.list_supplier_contacts(s)) == [{"email", "sales@kraana.ee", true}]
    end

    test "a supplier with only contact_info reads back exactly what was written" do
      s = supplier(%{contact_info: "Mari, +372 5555 1234, after 17:00"})
      assert stored(s).contact_info == "Mari, +372 5555 1234, after 17:00"

      {:ok, s} = Catalogue.update_supplier(s, %{contact_info: "Jüri, +372 5555 9999"})
      assert s.contact_info == "Jüri, +372 5555 9999"

      assert summary(Catalogue.list_supplier_contacts(s)) == [
               {"other", "Jüri, +372 5555 9999", true}
             ]
    end

    test "update_supplier replaces that kind's primary and keeps the others" do
      s = supplier()

      {:ok, s} =
        Catalogue.put_supplier_contacts(s, [
          %{kind: "person", value: "Mari"},
          %{kind: "email", value: "old@kraana.ee"}
        ])

      {:ok, s} = Catalogue.update_supplier(s, %{contact_info: "new@kraana.ee"})

      assert s.contact_info == "Mari, new@kraana.ee"

      assert summary(Catalogue.list_supplier_contacts(s)) == [
               {"person", "Mari", true},
               {"email", "new@kraana.ee", true}
             ]
    end

    test "writing an existing non-primary value promotes it" do
      s = supplier()

      {:ok, s} =
        Catalogue.put_supplier_contacts(s, [
          %{kind: "email", value: "a@kraana.ee"},
          %{kind: "email", value: "b@kraana.ee"}
        ])

      {:ok, s} = Catalogue.update_supplier(s, %{contact_info: "b@kraana.ee"})

      assert summary(Catalogue.list_supplier_contacts(s)) == [
               {"email", "a@kraana.ee", false},
               {"email", "b@kraana.ee", true}
             ]
    end

    test "a blank write unsets every primary and clears the column" do
      s = supplier(%{contact_info: "sales@kraana.ee"})
      {:ok, s} = Catalogue.update_supplier(s, %{contact_info: ""})
      assert s.contact_info == nil
      assert summary(Catalogue.list_supplier_contacts(s)) == [{"email", "sales@kraana.ee", false}]
    end

    test "an update that leaves contact_info alone touches no contact" do
      s = supplier(%{contact_info: "sales@kraana.ee"})
      [before] = Catalogue.list_supplier_contacts(s)
      {:ok, s} = Catalogue.update_supplier(s, %{name: "Renamed"})
      assert [^before] = Catalogue.list_supplier_contacts(s)
    end

    test "an invalid supplier writes no contact" do
      assert {:error, %Ecto.Changeset{}} =
               Catalogue.create_supplier(%{name: "", contact_info: "sales@kraana.ee"})

      assert Repo.aggregate(SupplierContact, :count) == 0
    end
  end

  describe "the V8 backfill" do
    test "turns a supplier's contact_info into one classified primary, once" do
      # Rows written behind the context's back, as an install's would be
      # before V8.
      {:ok, a} = Repo.insert(%Supplier{name: "A", contact_info: " sales@kraana.ee "})
      {:ok, b} = Repo.insert(%Supplier{name: "B", contact_info: "+372 5555 1234"})
      {:ok, c} = Repo.insert(%Supplier{name: "C", contact_info: "call Mari"})
      {:ok, d} = Repo.insert(%Supplier{name: "D", contact_info: "   "})

      for stmt <- Migrations.up_statements("public"), do: Repo.query!(stmt)
      for stmt <- Migrations.up_statements("public"), do: Repo.query!(stmt)

      assert summary(Catalogue.list_supplier_contacts(a)) == [{"email", "sales@kraana.ee", true}]
      assert summary(Catalogue.list_supplier_contacts(b)) == [{"phone", "+372 5555 1234", true}]
      assert summary(Catalogue.list_supplier_contacts(c)) == [{"other", "call Mari", true}]
      assert Catalogue.list_supplier_contacts(d) == []

      # The SQL and the Elixir rules agree.
      for s <- [a, b, c], [contact] = Catalogue.list_supplier_contacts(s) do
        assert SupplierContact.classify(s.contact_info) == contact.kind
      end
    end
  end

  describe "the V8 backfill and classify/1 agree" do
    test "on whitespace, Unicode spaces and blanks, kind and value alike" do
      inputs = [
        "sales@kraana.ee\n",
        "sales@kraana.ee\r\n",
        "\tsales@kraana.ee",
        "\vsales@kraana.ee",
        "\u00a0sales@kraana.ee\u3000",
        "sales@kra\u2003ana.ee",
        "a\u00c5@b.cc",
        "https://kraana.ee\n",
        " https://kraana.ee",
        "+372 5555 1234\n",
        "\t+372 5555 1234",
        "Mari\nmari@kraana.ee",
        "HTTPS://KRAANA.EE",
        "call Mari "
      ]

      blanks = ["\n", "\u00a0", " \t\r\n "]

      rows =
        for text <- inputs ++ blanks do
          {:ok, s} = Repo.insert(%Supplier{name: "S", contact_info: text})
          {text, s}
        end

      for stmt <- Migrations.up_statements("public"), do: Repo.query!(stmt)

      for {text, s} <- rows do
        case Catalogue.list_supplier_contacts(s) do
          [] ->
            assert String.trim(text) == "", inspect(text)

          [contact] ->
            assert {contact.kind, contact.value} ==
                     {SupplierContact.classify(text), String.trim(text)},
                   inspect(text)
        end
      end

      assert Enum.count(rows, fn {_, s} -> Catalogue.list_supplier_contacts(s) == [] end) ==
               length(blanks)
    end
  end

  describe "edits build on the locked state and keep uuids" do
    test "a contact's uuid survives an unrelated edit" do
      s = supplier(%{contact_info: "sales@kraana.ee"})
      [c] = Catalogue.list_supplier_contacts(s)

      {:ok, _} = Catalogue.add_supplier_contact(s, %{kind: "phone", value: "+372 5555 1234"})
      assert c.uuid in Enum.map(Catalogue.list_supplier_contacts(s), & &1.uuid)

      {:ok, _} = Catalogue.add_supplier_contact(s, %{kind: "email", value: "info@kraana.ee"})
      {:ok, _} = Catalogue.delete_supplier_contact(s, c.uuid)

      assert summary(Catalogue.list_supplier_contacts(s)) == [
               {"phone", "+372 5555 1234", true},
               {"email", "info@kraana.ee", true}
             ]
    end

    test "two specs naming the same uuid: the second gets a fresh one" do
      s = supplier(%{contact_info: "sales@kraana.ee"})
      [c] = Catalogue.list_supplier_contacts(s)
      spec = %{uuid: c.uuid, kind: "email", value: "sales@kraana.ee"}

      assert {:ok, _} =
               Catalogue.put_supplier_contacts(s, [spec, %{spec | value: "info@kraana.ee"}])

      assert [%{uuid: uuid}, %{uuid: other}] = Catalogue.list_supplier_contacts(s)
      assert uuid == c.uuid
      refute other == c.uuid
    end

    test "a refused edit inside the caller's transaction leaves that transaction usable" do
      s = supplier()

      assert {:ok, :still_usable} =
               Repo.transaction(fn ->
                 assert {:error, %Ecto.Changeset{}} =
                          Catalogue.put_supplier_contacts(s, [%{kind: "nope", value: "x"}])

                 assert {:error, :not_found} =
                          Catalogue.set_primary_supplier_contact(s, Ecto.UUID.generate())

                 Repo.query!("SELECT 1")
                 :still_usable
               end)
    end

    test "set_primary on an unknown uuid is :not_found and writes nothing" do
      s = supplier(%{contact_info: "sales@kraana.ee"})

      assert {:error, :not_found} =
               Catalogue.set_primary_supplier_contact(s, Ecto.UUID.generate())

      assert stored(s).contact_info == "sales@kraana.ee"
    end
  end

  describe "legacy writes of the summary" do
    setup do
      s = supplier()

      {:ok, s} =
        Catalogue.put_supplier_contacts(s, [
          %{kind: "person", value: "Mari"},
          %{kind: "phone", value: "+372 5555 1234"},
          %{kind: "email", value: "a@kraana.ee"}
        ])

      %{s: s}
    end

    test "the summary written back as it reads changes nothing", %{s: s} do
      before = Catalogue.list_supplier_contacts(s)
      {:ok, s2} = Catalogue.update_supplier(s, %{contact_info: s.contact_info <> "\n"})
      assert s2.contact_info == "Mari, +372 5555 1234, a@kraana.ee"
      assert Catalogue.list_supplier_contacts(s) == before
    end

    test "an edited summary is the only primary and reads back as written", %{s: s} do
      text = "Mari, +372 5555 1234, b@kraana.ee"
      {:ok, s2} = Catalogue.update_supplier(s, %{contact_info: text})
      assert s2.contact_info == text

      {:ok, s3} = Catalogue.update_supplier(s2, %{contact_info: text <> " (sales)"})
      assert s3.contact_info == text <> " (sales)"

      contacts = Catalogue.list_supplier_contacts(s)
      assert length(contacts) == 4
      assert [%{kind: "other"}] = Enum.filter(contacts, & &1.is_primary)
    end

    test "a stored contact that no longer validates is an error on contact_info", %{s: s} do
      Repo.insert_all(SupplierContact, [
        %{
          supplier_uuid: s.uuid,
          kind: "other",
          value: "\n",
          position: 9,
          inserted_at: DateTime.utc_now(:second),
          updated_at: DateTime.utc_now(:second)
        }
      ])

      assert {:error, %Ecto.Changeset{data: %Supplier{}} = cs} =
               Catalogue.update_supplier(s, %{contact_info: "c@kraana.ee"})

      assert cs.errors[:contact_info]
    end
  end

  test "lengths count code points, as varchar does" do
    s = supplier()
    # "e" + combining acute: 260 graphemes, 520 code points.
    long = String.duplicate("e\u0301", 260)

    assert {:error, %Ecto.Changeset{}} =
             Catalogue.put_supplier_contacts(s, [%{kind: "other", value: long}])

    assert {:error, %Ecto.Changeset{}} = Catalogue.update_supplier(s, %{contact_info: long})

    contacts = [
      %{kind: "person", value: String.duplicate("e\u0301", 200), is_primary: true},
      %{kind: "other", value: String.duplicate("e\u0301", 200), is_primary: true}
    ]

    assert String.length(Catalogue.supplier_contact_summary(contacts)) <= 500
    assert length(String.to_charlist(Catalogue.supplier_contact_summary(contacts))) == 500
  end

  describe "resolve" do
    test "a local supplier's email, phone and web address come from its primaries" do
      s = supplier()

      {:ok, _} =
        Catalogue.put_supplier_contacts(s, [
          %{kind: "email", value: "sales@kraana.ee"},
          %{kind: "phone", value: "+372 5555 1234"},
          %{kind: "url", value: "https://kraana.ee"}
        ])

      assert {:ok, %{email: "sales@kraana.ee", phone: "+372 5555 1234"} = resolved} =
               Catalogue.resolve_supplier(s.uuid)

      assert resolved.website == "https://kraana.ee"

      assert %{email: "sales@kraana.ee"} = Catalogue.resolve_suppliers([s.uuid])[s.uuid]

      assert %{phone: "+372 5555 1234"} =
               Enum.find(Catalogue.list_all_suppliers(), &(&1.uuid == s.uuid))
    end

    test "primary_supplier_contacts/1 batches and skips non-uuids" do
      s = supplier(%{contact_info: "sales@kraana.ee"})

      assert Catalogue.primary_supplier_contacts([s.uuid, "nope"]) == %{
               s.uuid => %{"email" => "sales@kraana.ee"}
             }

      assert Catalogue.primary_supplier_contacts([]) == %{}
    end
  end

  test "supplier_contact_summary/1 cuts at the column's 500 characters" do
    long = String.duplicate("x", 400)

    contacts = [
      %{kind: "other", value: long, is_primary: true},
      %{kind: "person", value: long, is_primary: true}
    ]

    assert String.length(Catalogue.supplier_contact_summary(contacts)) == 500
    assert Catalogue.supplier_contact_summary([]) == nil
  end
end
