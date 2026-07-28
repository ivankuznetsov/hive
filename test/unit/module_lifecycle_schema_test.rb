require "json_schemer"
require "test_helper"

class ModuleLifecycleSchemaTest < Minitest::Test
  def test_success_and_error_payloads_validate
    lifecycle = JSONSchemer.schema(Pathname(Hive::Schemas.schema_path("hive-module-lifecycle")))
    list = JSONSchemer.schema(Pathname(Hive::Schemas.schema_path("hive-module-list")))
    success = {
      "schema" => "hive-module-lifecycle", "schema_version" => 1, "ok" => true,
      "operation" => "install", "status" => "preview", "name" => "demo",
      "preview_receipt" => "1.#{'a' * 64}", "candidate" => {},
      "configuration_digest" => "b" * 64, "diff" => {}, "proposed" => {}, "selection" => nil
    }
    error = Hive::Schemas::ErrorEnvelope.build(
      schema: "hive-module-lifecycle", error: Hive::ConfigError.new("bad"), error_kind: "config"
    )
    listing = {
      "schema" => "hive-module-list", "schema_version" => 1, "ok" => true, "modules" => []
    }

    assert_empty lifecycle.validate(success).to_a
    assert_empty lifecycle.validate(error).to_a
    assert_empty list.validate(listing).to_a
  end
end
