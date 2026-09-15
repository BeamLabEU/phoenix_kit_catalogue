[
  # Gettext.Backend expands into code that constructs %Expo.PluralForms{}
  # literals inline; that struct is @opaque in Expo, so dialyzer flags the
  # generated call to Gettext.Plural.plural/2. Known upstream false positive.
  {"lib/phoenix_kit_catalogue/gettext.ex", :call_without_opaque},

  # Ecto.Multi/Ecto.Query are @opaque; piping a freshly-built query into
  # Multi.update_all/3 makes dialyzer flag the opaque-subterm mismatch even
  # though the call is correct. Same known Ecto+dialyzer false positive as
  # the gettext.ex entry above.
  {"lib/phoenix_kit_catalogue/catalogue/item_supplier_infos.ex", :call_without_opaque},

  # Mix tasks: the :mix application isn't in the dialyzer PLT, so any call
  # into Mix.Task/Mix.shell() reads as an unknown callback/function. Inherent
  # to dialyzing a Mix.Task module, not specific to this file's code.
  {"lib/mix/tasks/phoenix_kit_catalogue.audit_supplier_refs.ex", :callback_info_missing},
  {"lib/mix/tasks/phoenix_kit_catalogue.audit_supplier_refs.ex", :unknown_function},

  # `phoenix_kit_comments` is a SOFT dependency: this package does not declare
  # it (CRM does), so the module is absent from the PLT and every call into it
  # reads as unknown. Each one is guarded at runtime by `comments_available?/0`
  # — `Code.ensure_loaded?` + the module's own `enabled?/0` — and the
  # affordances simply do not render when the package is missing.
  #
  # Scoped to :unknown_function deliberately. A real type error in this file
  # still fails the build; only the absent-module noise is suppressed.
  {"lib/phoenix_kit_catalogue/web/item_form_live.ex", :unknown_function}
]
