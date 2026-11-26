defmodule PhoenixKitCatalogue.Catalogue.SupplierContacts do
  @moduledoc """
  Supplier contacts — the ways to reach a supplier, as
  `PhoenixKitCatalogue.Schemas.SupplierContact` rows (V8): any number per
  kind (person, phone, email, url, address, other), at most one primary
  per kind.

  ## One setter, two columns

  The supplier's old free-text `contact_info` column is kept, and kept in
  step: it is always the one-line summary of the primaries, in kind order
  (`"Mari Maasikas, +372 5555 5555, sales@example.com"`). Everything that
  writes contacts goes through this module, and this module is the only
  writer of that column:

    * `put_supplier_contacts/3` (and `add_supplier_contact/3` /
      `delete_supplier_contact/3`, which build a new list and call it)
      replaces the list, settles the primaries — the first flagged
      contact of a kind stays primary, a kind with none flagged gets its
      first — and rewrites `contact_info` from them;
    * a legacy write of `contact_info` itself (`create_supplier/2` or
      `update_supplier/3` with the field, an import) is routed here by
      `Catalogue.Suppliers` inside the same transaction: the text becomes
      the primary of the kind it looks like (`SupplierContact.classify/1`),
      replacing that kind's primary value or adding one, and the column
      is rewritten from the primaries. Free text of no one kind (an edited
      summary) becomes the `other` primary and the other kinds' primaries
      step down, so the column reads back exactly what was written; the
      current summary written back unchanged changes nothing. A blank
      write unsets every primary.

  Every edit reads the contacts under the supplier's row lock, so two
  concurrent edits build on each other. Contacts keep their uuid across
  edits.

  So a supplier with a single contact reads back exactly the text that was
  written — every install that has only ever used `contact_info` sees no
  change — and one with several reads the summary.

  Public surface is re-exported from `PhoenixKitCatalogue.Catalogue`.
  """

  import Ecto.Query, warn: false

  alias PhoenixKitCatalogue.Catalogue.{ActivityLog, Helpers, PubSub}
  alias PhoenixKitCatalogue.Schemas.{Supplier, SupplierContact}

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @summary_max 500

  @typedoc """
  One contact as a caller hands it to `put_supplier_contacts/3`: `:kind`,
  `:value`, optional `:label` and `:is_primary`. Atom or string keys.
  """
  @type spec :: map()

  @doc "A supplier's contacts, in their order."
  @spec list_supplier_contacts(Supplier.t() | Ecto.UUID.t() | nil) :: [SupplierContact.t()]
  def list_supplier_contacts(%Supplier{uuid: uuid}), do: list_supplier_contacts(uuid)
  def list_supplier_contacts(nil), do: []

  def list_supplier_contacts(supplier_uuid) when is_binary(supplier_uuid) do
    if Helpers.uuid?(supplier_uuid) do
      supplier_uuid |> contacts_query() |> repo().all()
    else
      []
    end
  end

  @doc """
  The primary value of each kind for many suppliers at once, as
  `%{supplier_uuid => %{kind => value}}` — one query. Suppliers with no
  primary contact are absent.
  """
  @spec primary_supplier_contacts([Ecto.UUID.t()]) :: %{
          Ecto.UUID.t() => %{String.t() => String.t()}
        }
  def primary_supplier_contacts(supplier_uuids) when is_list(supplier_uuids) do
    case Enum.filter(supplier_uuids, &Helpers.uuid?/1) do
      [] ->
        %{}

      uuids ->
        from(c in SupplierContact,
          where: c.supplier_uuid in ^uuids and c.is_primary,
          select: {c.supplier_uuid, c.kind, c.value}
        )
        |> repo().all()
        |> Enum.reduce(%{}, fn {supplier_uuid, kind, value}, acc ->
          Map.update(acc, supplier_uuid, %{kind => value}, &Map.put(&1, kind, value))
        end)
    end
  rescue
    # A host whose chain has not reached V8 yet has no table: resolving a
    # supplier must keep working on the columns it has. Only that error —
    # a timeout or a lock failure is the caller's to see. (Inside a
    # caller's transaction the failed SELECT has already aborted it; a
    # host must reach V8 before relying on resolve there.)
    error in Postgrex.Error ->
      case error do
        %Postgrex.Error{postgres: %{code: :undefined_table}} -> %{}
        _ -> reraise error, __STACKTRACE__
      end
  end

  @doc """
  The `contact_info` text a set of contacts stands for: the primaries'
  values in kind order (`SupplierContact.kinds/0`), comma-separated, cut
  to the column's 500 characters. `nil` when there is no primary.
  """
  @spec contact_summary([SupplierContact.t() | map()]) :: String.t() | nil
  def contact_summary(contacts) when is_list(contacts) do
    order = SupplierContact.kinds() |> Enum.with_index() |> Map.new()

    contacts
    |> Enum.filter(&field(&1, :is_primary))
    |> Enum.sort_by(&Map.get(order, field(&1, :kind), map_size(order)))
    |> Enum.map(&field(&1, :value))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> case do
      [] -> nil
      values -> values |> Enum.join(", ") |> cut(@summary_max)
    end
  end

  # varchar(n) counts code points; String.slice/3 counts graphemes, which
  # can be more code points than the column takes.
  defp cut(text, max) do
    text |> String.to_charlist() |> Enum.take(max) |> List.to_string()
  end

  @doc """
  Replaces a supplier's contacts with `specs`, in that order, and rewrites
  `contact_info` from the primaries (see the moduledoc). Writes, logs
  (`supplier.contacts_updated`) and broadcasts nothing when the list is
  unchanged.

  Returns `{:ok, supplier}` with `:contacts` loaded and `contact_info`
  current, or `{:error, changeset}` for the first contact that does not
  validate (nothing is written then).
  """
  @spec put_supplier_contacts(Supplier.t(), [spec()], keyword()) ::
          {:ok, Supplier.t()} | {:error, Ecto.Changeset.t()}
  def put_supplier_contacts(%Supplier{} = supplier, specs, opts \\ []) when is_list(specs) do
    edit_contacts(supplier, fn _current -> specs end, opts)
  end

  # The read-modify-write every writer shares. `fun` gets the contacts as
  # they are under the supplier's row lock and returns the new spec list,
  # so two concurrent edits (two `add_supplier_contact/3`, say) each build
  # on the other's committed result instead of one silently replacing it.
  # A spec carrying the `:uuid` of a current contact keeps that row's uuid
  # and `inserted_at`, so a caller holding a uuid can still use it after an
  # unrelated edit.
  defp edit_contacts(supplier, fun, opts) do
    tx =
      repo().transaction(fn ->
        lock_supplier!(supplier)
        current = list_supplier_contacts(supplier)
        changesets = current |> fun.() |> build_changesets(supplier, current, &settle_primaries/1)

        case Enum.find(changesets, &(not &1.valid?)) do
          nil -> :ok
          bad -> repo().rollback(%{bad | action: :insert})
        end

        if Enum.map(current, &comparable/1) == Enum.map(changesets, &comparable/1) do
          {:unchanged, current}
        else
          replace!(supplier, changesets)
          {:written, write_summary!(supplier, changesets), length(current), length(changesets)}
        end
      end)

    after_edit(tx, supplier, opts)
  end

  defp build_changesets(specs, supplier, current, settle) do
    known = Map.new(current, &{&1.uuid, &1})

    specs
    |> Enum.with_index()
    |> Enum.map(fn {spec, index} ->
      {spec_attrs(spec, supplier.uuid, index), keep(spec, known)}
    end)
    |> then(fn pairs ->
      settled = pairs |> Enum.map(&elem(&1, 0)) |> settle.()
      Enum.zip_with(settled, pairs, fn attrs, {_, kept} -> contact_changeset(attrs, kept) end)
    end)
  end

  # The current row a spec names by uuid, if it names one of THIS
  # supplier's contacts (any other uuid is ignored: a fresh one is made).
  defp keep(spec, known) do
    case atomize(spec)[:uuid] do
      uuid when is_binary(uuid) -> Map.get(known, uuid)
      _ -> nil
    end
  end

  defp contact_changeset(attrs, nil), do: SupplierContact.changeset(%SupplierContact{}, attrs)

  defp contact_changeset(attrs, %SupplierContact{uuid: uuid, inserted_at: at}),
    do: SupplierContact.changeset(%SupplierContact{uuid: uuid, inserted_at: at}, attrs)

  @doc """
  Appends one contact (`attrs` as in `put_supplier_contacts/3`). A contact
  flagged `is_primary` takes over its kind's primary; the first of a kind
  becomes primary on its own.
  """
  @spec add_supplier_contact(Supplier.t(), spec(), keyword()) ::
          {:ok, Supplier.t()} | {:error, Ecto.Changeset.t()}
  def add_supplier_contact(%Supplier{} = supplier, attrs, opts \\ []) when is_map(attrs) do
    new = attrs |> atomize() |> Map.delete(:uuid)

    takes_over? = truthy?(new[:is_primary])
    kind = to_string(new[:kind])

    edit_contacts(
      supplier,
      fn current ->
        Enum.map(current, &step_down(&1, takes_over? and &1.kind == kind)) ++ [new]
      end,
      opts
    )
  end

  defp step_down(contact, true), do: %{to_spec(contact) | is_primary: false}
  defp step_down(contact, false), do: to_spec(contact)

  @doc """
  Removes one contact by uuid. When it was its kind's primary, the next
  contact of that kind becomes primary. An unknown uuid changes nothing.
  """
  @spec delete_supplier_contact(Supplier.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Supplier.t()} | {:error, Ecto.Changeset.t()}
  def delete_supplier_contact(%Supplier{} = supplier, contact_uuid, opts \\ []) do
    edit_contacts(
      supplier,
      fn current ->
        current |> Enum.reject(&(&1.uuid == contact_uuid)) |> Enum.map(&to_spec/1)
      end,
      opts
    )
  end

  @doc """
  Makes one contact the primary of its kind (the kind's old primary stops
  being one) and rewrites `contact_info`.
  """
  @spec set_primary_supplier_contact(Supplier.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Supplier.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def set_primary_supplier_contact(%Supplier{} = supplier, contact_uuid, opts \\ []) do
    edit_contacts(
      supplier,
      fn current ->
        case Enum.find(current, &(&1.uuid == contact_uuid)) do
          nil -> repo().rollback(:not_found)
          %SupplierContact{kind: kind} -> Enum.map(current, &primary_spec(&1, kind, contact_uuid))
        end
      end,
      opts
    )
  end

  defp primary_spec(%SupplierContact{kind: kind} = c, kind, contact_uuid),
    do: %{to_spec(c) | is_primary: c.uuid == contact_uuid}

  defp primary_spec(c, _kind, _contact_uuid), do: to_spec(c)

  @doc false
  # The legacy half of the setter: `Catalogue.Suppliers` calls this inside
  # the transaction that just wrote `contact_info` through the supplier
  # changeset. Turns that text into the primary of its kind and rewrites
  # the column from the primaries. Returns the supplier as now stored.
  @spec apply_legacy_contact_info(Supplier.t()) :: Supplier.t()
  def apply_legacy_contact_info(%Supplier{} = supplier) do
    lock_supplier!(supplier)
    current = list_supplier_contacts(supplier)
    text = String.trim(supplier.contact_info || "")

    specs =
      if text == contact_summary(current),
        # The summary written back as it reads (a form re-saving it, an
        # export re-imported): nothing to change.
        do: Enum.map(current, &to_spec/1),
        else: current |> Enum.map(&to_spec/1) |> legacy_specs(text)

    changesets = build_changesets(specs, supplier, current, & &1)

    case Enum.find(changesets, &(not &1.valid?)) do
      nil -> :ok
      bad -> repo().rollback(%{bad | action: :update})
    end

    if Enum.map(current, &comparable/1) != Enum.map(changesets, &comparable/1) do
      replace!(supplier, changesets)
    end

    write_summary!(supplier, changesets)
  end

  # Blank: no primaries. Otherwise the text is the primary of its kind —
  # an existing contact of that kind with the same value is promoted, else
  # the kind's primary takes the new value, else a new primary is added.
  defp legacy_specs(specs, ""), do: Enum.map(specs, &%{&1 | is_primary: false})

  # Free text that is no one kind (`"Mari, +372 5555 5555"`, an edited
  # summary) stands for the whole summary: it becomes the only primary, the
  # other kinds' primaries stay as plain contacts, and the column reads back
  # exactly what was written — never the old primaries plus the new text.
  defp legacy_specs(specs, text) do
    case SupplierContact.classify(text) do
      "other" -> legacy_free_text(specs, text)
      kind -> legacy_of_kind(specs, text, kind)
    end
  end

  defp legacy_free_text(specs, text) do
    specs
    |> Enum.map(fn
      %{kind: "other"} = spec -> spec
      spec -> %{spec | is_primary: false}
    end)
    |> legacy_of_kind(text, "other")
  end

  defp legacy_of_kind(specs, text, kind) do
    same = Enum.find_index(specs, &(&1.kind == kind and &1.value == text))
    primary = Enum.find_index(specs, &(&1.kind == kind and &1.is_primary))

    cond do
      same != nil ->
        specs
        |> Enum.with_index()
        |> Enum.map(fn
          {%{kind: ^kind} = spec, ^same} -> %{spec | is_primary: true}
          {%{kind: ^kind} = spec, _} -> %{spec | is_primary: false}
          {spec, _} -> spec
        end)

      primary != nil ->
        List.update_at(specs, primary, &%{&1 | value: text})

      true ->
        specs ++ [%{kind: kind, value: text, label: nil, is_primary: true}]
    end
  end

  defp after_edit(tx, supplier, opts) do
    case tx do
      {:ok, {:unchanged, current}} ->
        {:ok, %{reload(supplier) | contacts: current}}

      {:ok, {:written, updated, before, total}} ->
        ActivityLog.log(%{
          action: "supplier.contacts_updated",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "supplier",
          resource_uuid: supplier.uuid,
          metadata: %{"name" => supplier.name, "before" => before, "total" => total}
        })

        PubSub.broadcast(:supplier, supplier.uuid)
        {:ok, %{updated | contacts: list_supplier_contacts(supplier)}}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  defp replace!(supplier, changesets) do
    from(c in SupplierContact, where: c.supplier_uuid == ^supplier.uuid) |> repo().delete_all()

    Enum.each(changesets, fn changeset ->
      case repo().insert(changeset) do
        {:ok, _} -> :ok
        {:error, changeset} -> repo().rollback(changeset)
      end
    end)
  end

  defp write_summary!(supplier, changesets) do
    summary = changesets |> Enum.map(&Ecto.Changeset.apply_changes/1) |> contact_summary()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {1, [updated]} =
      from(s in Supplier, where: s.uuid == ^supplier.uuid, select: s)
      |> repo().update_all(set: [contact_info: summary, updated_at: now])

    updated
  end

  defp reload(supplier), do: repo().get!(Supplier, supplier.uuid)

  defp lock_supplier!(supplier) do
    from(s in Supplier, where: s.uuid == ^supplier.uuid, lock: "FOR UPDATE", select: s.uuid)
    |> repo().one!()
  end

  defp contacts_query(supplier_uuid) do
    from(c in SupplierContact,
      where: c.supplier_uuid == ^supplier_uuid,
      order_by: [asc: c.position, asc: c.inserted_at]
    )
  end

  # First flagged contact of a kind stays primary, later flags drop; a kind
  # with no flag at all gets its first contact.
  defp settle_primaries(attrs_list) do
    flagged_kinds =
      attrs_list |> Enum.filter(& &1.is_primary) |> Enum.map(& &1.kind) |> MapSet.new()

    {settled, _seen} =
      Enum.map_reduce(attrs_list, MapSet.new(), fn attrs, seen ->
        kind = attrs.kind

        primary? =
          not MapSet.member?(seen, kind) and
            (attrs.is_primary or not MapSet.member?(flagged_kinds, kind))

        seen = if primary?, do: MapSet.put(seen, kind), else: seen
        {%{attrs | is_primary: primary?}, seen}
      end)

    settled
  end

  defp spec_attrs(spec, supplier_uuid, index) do
    spec = atomize(spec)

    %{
      supplier_uuid: supplier_uuid,
      kind: spec[:kind] && to_string(spec[:kind]),
      value: spec[:value],
      label: spec[:label],
      is_primary: truthy?(spec[:is_primary]),
      position: index
    }
  end

  defp truthy?(value), do: value in [true, "true", "on", "1", 1]

  defp atomize(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {key(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp key("kind"), do: :kind
  defp key("value"), do: :value
  defp key("label"), do: :label
  defp key("is_primary"), do: :is_primary
  defp key("uuid"), do: :uuid
  defp key(other), do: other

  defp to_spec(%SupplierContact{} = c),
    do: %{uuid: c.uuid, kind: c.kind, value: c.value, label: c.label, is_primary: c.is_primary}

  defp comparable(%Ecto.Changeset{} = changeset),
    do: changeset |> Ecto.Changeset.apply_changes() |> comparable()

  defp comparable(%SupplierContact{} = c), do: {c.kind, c.value, c.label, c.is_primary}

  defp field(%{} = contact, key), do: Map.get(contact, key)
end
