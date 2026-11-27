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
      is rewritten from the primaries. A blank write unsets every primary.

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
    # supplier must keep working on the columns it has.
    Postgrex.Error -> %{}
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
      values -> values |> Enum.join(", ") |> String.slice(0, @summary_max)
    end
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
    changesets =
      specs
      |> Enum.with_index()
      |> Enum.map(fn {spec, index} -> spec_attrs(spec, supplier.uuid, index) end)
      |> settle_primaries()
      |> Enum.map(&SupplierContact.changeset(%SupplierContact{}, &1))

    case Enum.find(changesets, &(not &1.valid?)) do
      nil -> write_if_changed(supplier, changesets, opts)
      bad -> {:error, %{bad | action: :insert}}
    end
  end

  @doc """
  Appends one contact (`attrs` as in `put_supplier_contacts/3`). A contact
  flagged `is_primary` takes over its kind's primary; the first of a kind
  becomes primary on its own.
  """
  @spec add_supplier_contact(Supplier.t(), spec(), keyword()) ::
          {:ok, Supplier.t()} | {:error, Ecto.Changeset.t()}
  def add_supplier_contact(%Supplier{} = supplier, attrs, opts \\ []) when is_map(attrs) do
    current = list_supplier_contacts(supplier)
    new = atomize(attrs)

    current_specs =
      Enum.map(current, fn c ->
        spec = to_spec(c)

        if new[:is_primary] in [true, "true"] and c.kind == to_string(new[:kind]),
          do: %{spec | is_primary: false},
          else: spec
      end)

    put_supplier_contacts(supplier, current_specs ++ [new], opts)
  end

  @doc """
  Removes one contact by uuid. When it was its kind's primary, the next
  contact of that kind becomes primary. An unknown uuid changes nothing.
  """
  @spec delete_supplier_contact(Supplier.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Supplier.t()} | {:error, Ecto.Changeset.t()}
  def delete_supplier_contact(%Supplier{} = supplier, contact_uuid, opts \\ []) do
    specs =
      supplier
      |> list_supplier_contacts()
      |> Enum.reject(&(&1.uuid == contact_uuid))
      |> Enum.map(&to_spec/1)

    put_supplier_contacts(supplier, specs, opts)
  end

  @doc """
  Makes one contact the primary of its kind (the kind's old primary stops
  being one) and rewrites `contact_info`.
  """
  @spec set_primary_supplier_contact(Supplier.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Supplier.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def set_primary_supplier_contact(%Supplier{} = supplier, contact_uuid, opts \\ []) do
    current = list_supplier_contacts(supplier)

    case Enum.find(current, &(&1.uuid == contact_uuid)) do
      nil ->
        {:error, :not_found}

      %SupplierContact{kind: kind} ->
        specs = Enum.map(current, &primary_spec(&1, kind, contact_uuid))
        put_supplier_contacts(supplier, specs, opts)
    end
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
    specs = current |> Enum.map(&to_spec/1) |> legacy_specs(text)

    changesets =
      specs
      |> Enum.with_index()
      |> Enum.map(fn {spec, index} -> spec_attrs(spec, supplier.uuid, index) end)
      |> Enum.map(&SupplierContact.changeset(%SupplierContact{}, &1))

    if Enum.map(current, &comparable/1) != Enum.map(changesets, &comparable/1) do
      replace!(supplier, changesets)
    end

    write_summary!(supplier, changesets)
  end

  # Blank: no primaries. Otherwise the text is the primary of its kind —
  # an existing contact of that kind with the same value is promoted, else
  # the kind's primary takes the new value, else a new primary is added.
  defp legacy_specs(specs, ""), do: Enum.map(specs, &%{&1 | is_primary: false})

  defp legacy_specs(specs, text) do
    kind = SupplierContact.classify(text)
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

  defp write_if_changed(supplier, changesets, opts) do
    tx =
      repo().transaction(fn ->
        lock_supplier!(supplier)
        current = list_supplier_contacts(supplier)

        if Enum.map(current, &comparable/1) == Enum.map(changesets, &comparable/1) do
          {:unchanged, current}
        else
          replace!(supplier, changesets)
          {:written, write_summary!(supplier, changesets), length(current)}
        end
      end)

    case tx do
      {:ok, {:unchanged, current}} ->
        {:ok, %{reload(supplier) | contacts: current}}

      {:ok, {:written, updated, before}} ->
        ActivityLog.log(%{
          action: "supplier.contacts_updated",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "supplier",
          resource_uuid: supplier.uuid,
          metadata: %{
            "name" => supplier.name,
            "before" => before,
            "total" => length(changesets)
          }
        })

        PubSub.broadcast(:supplier, supplier.uuid)
        {:ok, %{updated | contacts: list_supplier_contacts(supplier)}}

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
      is_primary: spec[:is_primary] in [true, "true"],
      position: index
    }
  end

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
  defp key(other), do: other

  defp to_spec(%SupplierContact{} = c),
    do: %{kind: c.kind, value: c.value, label: c.label, is_primary: c.is_primary}

  defp comparable(%Ecto.Changeset{} = changeset),
    do: changeset |> Ecto.Changeset.apply_changes() |> comparable()

  defp comparable(%SupplierContact{} = c), do: {c.kind, c.value, c.label, c.is_primary}

  defp field(%{} = contact, key), do: Map.get(contact, key)
end
