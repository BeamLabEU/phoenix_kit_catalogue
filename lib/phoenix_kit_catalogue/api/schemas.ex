defmodule PhoenixKitCatalogue.API.Schemas do
  @moduledoc false
  # JSON Schema (string keys) for the catalogue's shop API tools. Only the
  # keywords core's validator implements are used (type, enum, required,
  # properties, additionalProperties, minimum/maximum, minLength/maxLength,
  # minItems/maxItems, items). `close_schema/2` closes the ROOT only, so every
  # nested object closes itself: a field a tool does not declare (base_price,
  # markup, discount, raw data) is a validation error at any depth.

  alias PhoenixKitCatalogue.API.Presenter
  alias PhoenixKitCatalogue.Schemas.Item

  @uuid %{"type" => "string", "minLength" => 36, "maxLength" => 36}
  @statuses ~w(active inactive discontinued)

  def uuid, do: @uuid
  def statuses, do: @statuses
  def units, do: Item.allowed_units()

  def text(max), do: %{"type" => "string", "minLength" => 1, "maxLength" => max}
  def nullable_text(max), do: %{"type" => ["string", "null"], "maxLength" => max}

  # ROW-LEVEL fields (refs, row ids, names, parents, categories). The schema
  # checks the type and an upper bound only, never the shape: a malformed id, a
  # blank sku or a blank name inside a row must reach the handler so that THAT
  # row answers `not_found` / `validation_failed` and the other rows are still
  # processed (a single row's error never stops the other rows). A
  # `minLength` here would turn one bad row into one 422 for the whole request.
  # The strict `@uuid` / `text/1` stay for request-level scalars (`catalogue_id`,
  # `category_id` of a list filter, `cursor`), where a request-level error is right.
  @row_id %{"type" => "string", "maxLength" => 200}
  def row_id, do: @row_id
  def row_text(max), do: %{"type" => "string", "maxLength" => max}
  def row_nullable_id, do: %{"type" => ["string", "null"], "maxLength" => 200}

  @doc "A reference: an object of which the handler requires exactly one key."
  def ref do
    %{
      "type" => "object",
      "properties" => %{
        "id" => @row_id,
        "sku" => row_text(100),
        "external_id" => row_text(200)
      },
      "additionalProperties" => false
    }
  end

  @doc "`[{set_id, values}]`, the attribute sets of an item and the value keys selected in each."
  def attributes do
    %{
      "type" => "array",
      "maxItems" => 20,
      "items" => %{
        "type" => "object",
        "required" => ["set_id", "values"],
        "properties" => %{
          "set_id" => @row_id,
          "values" => %{"type" => "array", "maxItems" => 200, "items" => row_text(200)}
        },
        "additionalProperties" => false
      }
    }
  end

  def list_categories do
    %{
      "type" => "object",
      "properties" => %{"catalogue_id" => @uuid},
      "additionalProperties" => false
    }
  end

  def list_products do
    %{
      "type" => "object",
      "properties" => %{
        "catalogue_id" => @uuid,
        "category_id" => @uuid,
        "status" => %{"type" => "string", "enum" => @statuses},
        "include_deleted" => %{"type" => "boolean"},
        "updated_since" => %{"type" => "string", "minLength" => 10, "maxLength" => 40},
        "q" => %{"type" => "string", "maxLength" => 200},
        "limit" => %{"type" => "integer", "minimum" => 1},
        "cursor" => %{"type" => "string", "maxLength" => 300},
        "fields" => fields()
      },
      "additionalProperties" => false
    }
  end

  def get_products do
    %{
      "type" => "object",
      "required" => ["refs"],
      "properties" => %{
        "catalogue_id" => @uuid,
        "refs" => %{"type" => "array", "minItems" => 1, "maxItems" => 50, "items" => ref()},
        "fields" => fields()
      },
      "additionalProperties" => false
    }
  end

  defp fields do
    %{
      "type" => "array",
      "maxItems" => 30,
      "items" => %{"type" => "string", "enum" => Presenter.item_fields()}
    }
  end

  # --- outputs (documentation for OpenAPI and MCP; core does not validate them) -----------

  @doc "The category tree: `{catalogue_id, count, categories: [node]}`."
  def categories_output do
    %{
      "type" => "object",
      "properties" => %{
        "catalogue_id" => %{"type" => "string"},
        "count" => %{"type" => "integer"},
        "categories" => %{"type" => "array", "items" => %{"type" => "object"}}
      }
    }
  end

  @doc "The batch answer: `{results: [row], summary: {action => count}}`."
  def batch_output(row_extra \\ %{}) do
    %{
      "type" => "object",
      "properties" => %{
        "results" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" =>
              Map.merge(
                %{
                  "ref" => %{"type" => "object"},
                  "action" => %{
                    "type" => "string",
                    "enum" => ~w(created updated unchanged skipped removed found error)
                  },
                  "id" => %{"type" => ["string", "null"]},
                  "error" => %{
                    "type" => "object",
                    "properties" => %{
                      "code" => %{"type" => "string"},
                      "message" => %{"type" => "string"},
                      "context" => %{"type" => "object"}
                    }
                  }
                },
                row_extra
              )
          }
        },
        "summary" => %{"type" => "object", "additionalProperties" => %{"type" => "integer"}},
        "warnings" => %{"type" => "array", "items" => %{"type" => "object"}}
      }
    }
  end

  def list_products_output do
    %{
      "type" => "object",
      "properties" => %{
        "items" => %{"type" => "array", "items" => %{"type" => "object"}},
        "next_cursor" => %{"type" => ["string", "null"]},
        "count" => %{"type" => "integer"},
        "warnings" => %{"type" => "array", "items" => %{"type" => "object"}}
      }
    }
  end
end
