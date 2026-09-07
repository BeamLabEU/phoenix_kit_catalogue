defmodule PhoenixKitCatalogue.Catalogue.Slugs do
  @moduledoc """
  Per-language slug generation for catalogue items and categories.

  `slug` is a flat `lang -> value` map (see the moduledoc amendment in the
  design spec): secondary languages in the multilang `data` column store
  overrides only, and replaying that merge inside a DB trigger would be
  expensive, so the slug column is written in full for every language up
  front instead.

  The generation rule (`from_title/3`) is ported from
  `PhoenixKitEcommerce.AITranslatable`'s private `slug_base/3`: only the
  head segment of a title is slug-worthy (long SEO titles pack a
  breadcrumb/marketing tail after a `|` or a spaced dash), the result is
  capped at a word boundary, and a title with no romanizable content
  (CJK, Arabic, emoji) falls back to a stable hash rather than an empty
  string. Unlike that adapter, an unromanizable title here does NOT
  borrow the default-language slug — it simply hashes on its own, with no
  identity tail, so a bare CJK title never silently serves another
  language's URL.

  ## `maybe_generate/3` is NOT wired into `Item.changeset/2` / `Category.changeset/2`

  `Catalogue.duplicate_category/1` (and any other internal copy path)
  creates a subtree's items/categories verbatim — same multilang `data`,
  same name, deliberately no suffix (see
  `PhoenixKitCatalogue.Catalogue.DuplicationTest` — "Nested copies keep
  their translations verbatim"). Auto-generating a slug from `:name` on
  every `create_item`/`create_category` call would derive the SAME slug
  for the original and its copy and fail the very
  `unique_constraint/3` this module asks callers to declare — a
  duplicate that used to succeed would start erroring, which the design
  spec's regression rule for this change forbids.

  So generation is explicit, not automatic: a caller that wants an
  empty slug filled from the name — the item/category form, in
  practice — calls `maybe_generate/3` itself on its own changeset
  before persisting. A plain `create_item`/`create_category` call
  (duplication, bulk import, any other context) leaves `:slug` exactly
  as given (`%{}` by default) and is unaffected.
  """

  alias PhoenixKit.Utils.Multilang
  alias PhoenixKit.Utils.Slug
  alias PhoenixKitCatalogue.Catalogue.Translations

  @max_len 60
  @head_split ~r/\s+[-–—]\s+|\|/u
  @tail_digits ~r/-(\d+)$/
  @hash_len 12
  @lang_key ~r/^[a-z]{2}-[A-Z]{2}$/

  @doc """
  A URL slug derived from `title`, generated in `lang`.

  Only the first non-blank segment before a `|` or a spaced dash (` - `,
  ` – `, ` — `) is used, capped to 60 characters at a word boundary. A
  title that slugifies to `""` (no romanizable content in `lang`) falls
  back to `"item-" <> <12 hex chars of sha256(title)>` — no identity tail.

  `opts[:default_slug]` — when the derived base is non-empty and this
  ends in a numeric tail (`-22153`), the tail is carried onto the result
  (unless already present), so every language of the same record shares
  one machine-imported identity suffix.
  """
  @spec from_title(String.t(), String.t(), keyword()) :: String.t()
  def from_title(title, lang, opts \\ []) when is_binary(title) and is_binary(lang) do
    base =
      title
      |> head_segment()
      |> Slug.slugify(locale: lang)
      |> cap_word_boundary(@max_len)

    case base do
      "" -> "item-" <> hash(title)
      slug -> with_identity_tail(slug, opts[:default_slug])
    end
  end

  @doc """
  Fills missing per-language slugs on `changeset`'s `field` (default use
  is `:slug`) from the multilang name stored under `:data`, for every
  language present there. A language that already has a non-blank slug
  is left alone (write-once — renaming must not move a live URL).

  `opts[:from]` names the source column (`:name` for both items and
  categories); its per-language text is read via
  `PhoenixKitCatalogue.Catalogue.Translations.translated_name/2`.
  """
  @spec maybe_generate(Ecto.Changeset.t(), atom(), keyword()) :: Ecto.Changeset.t()
  def maybe_generate(%Ecto.Changeset{} = changeset, field, opts) do
    source_field = Keyword.fetch!(opts, :from)
    data = Ecto.Changeset.get_field(changeset, :data) || %{}
    slug_map = Ecto.Changeset.get_field(changeset, field) || %{}
    source = %{data: data, name: Ecto.Changeset.get_field(changeset, source_field)}
    default_slug = default_lang_slug(data, slug_map)

    updated =
      data
      |> present_languages()
      |> Enum.reduce(slug_map, &fill_language(&1, &2, source, default_slug))

    if updated == slug_map do
      changeset
    else
      Ecto.Changeset.put_change(changeset, field, updated)
    end
  end

  defp fill_language(lang, slug_map, source, default_slug) do
    case Map.get(slug_map, lang) do
      value when is_binary(value) and value != "" ->
        slug_map

      _ ->
        case Translations.translated_name(source, lang) do
          title when is_binary(title) and title != "" ->
            Map.put(slug_map, lang, from_title(title, lang, default_slug: default_slug))

          _ ->
            slug_map
        end
    end
  end

  # A genuinely multilang `data` (one carrying `_primary_language`) has
  # one real per-language key for every language it stores translations
  # for, PLUS whatever sibling namespaces other code keeps at the same
  # top level (`"meta"`, an extension's `data["ecommerce"]`, …) — those
  # are not languages and must never reach `fill_language/4`, or two
  # unrelated items sharing a namespace key would collide on a slug
  # generated FOR that key and only one could ever save. Filtering to
  # the `xx-YY` shape every real language code has (see
  # `PhoenixKit.Utils.Multilang`'s moduledoc) keeps this correct without
  # having to know every namespace some other module might add.
  #
  # Flat `data` (no `_primary_language` — an item/category that has
  # never been touched through the multilang form) still gets exactly
  # one slug, in the site's primary language: the item/category forms
  # always render the slug input and promise "auto-generated from the
  # name" regardless of whether multilang is on, so a save with a blank
  # slug must fill it.
  defp present_languages(data) do
    if Multilang.multilang_data?(data) do
      data
      |> Map.keys()
      |> Enum.filter(&(&1 =~ @lang_key))
    else
      [Multilang.primary_language()]
    end
  end

  # The primary language's own slug (falling back to the first non-blank
  # value present) — the source of the numeric identity tail every other
  # language's generated slug carries.
  defp default_lang_slug(data, slug_map) do
    primary =
      if Multilang.multilang_data?(data),
        do: Map.get(data, "_primary_language"),
        else: Multilang.primary_language()

    case Map.get(slug_map, primary) do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        slug_map |> Map.values() |> Enum.find(&(is_binary(&1) and &1 != ""))
    end
  end

  # The first non-blank segment before a `|` or a spaced dash. Falls back
  # to the whole (trimmed) title when every segment is blank.
  defp head_segment(title) do
    title
    |> String.split(@head_split)
    |> Enum.map(&String.trim/1)
    |> Enum.find(&(&1 != ""))
    |> case do
      nil -> String.trim(title)
      segment -> segment
    end
  end

  # Cuts to `max_len` at a word boundary: hard-cut to `max_len`, then drop
  # the trailing partial word (back to the last `-`) and any trailing `-`.
  # No `-` inside the cut string -> hard cut, unchanged. When the cut
  # lands exactly on a boundary (the character right after it is `-`),
  # the sliced string is already whole words — kept as is.
  defp cap_word_boundary(slug, max_len) do
    if String.length(slug) <= max_len do
      slug
    else
      sliced = String.slice(slug, 0, max_len)

      cond do
        String.at(slug, max_len) == "-" ->
          sliced

        String.split(sliced, "-") == [sliced] ->
          sliced

        true ->
          sliced
          |> String.split("-")
          |> Enum.drop(-1)
          |> Enum.join("-")
          |> String.trim_trailing("-")
      end
    end
  end

  defp with_identity_tail(base, nil), do: base

  defp with_identity_tail(base, default_slug) when is_binary(default_slug) do
    case Regex.run(@tail_digits, default_slug) do
      [_, digits] ->
        tail = "-" <> digits
        if String.ends_with?(base, tail), do: base, else: base <> tail

      nil ->
        base
    end
  end

  defp hash(text) do
    :crypto.hash(:sha256, text)
    |> Base.encode16(case: :lower)
    |> binary_part(0, @hash_len)
  end
end
