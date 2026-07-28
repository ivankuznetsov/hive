require "test_helper"
require "json_schemer"

class ModuleStatusSchemaTest < Minitest::Test
  def test_new_module_operation_schemas_are_registered_and_valid
    %w[hive-module-status hive-module-doctor hive-module-dry-run].each do |name|
      assert_equal 1, Hive::Schemas::SCHEMA_VERSIONS.fetch(name)
      schema = JSONSchemer.schema(Pathname(Hive::Schemas.schema_path(name)))
      assert schema.valid?(error_payload(name)), name
    end
  end

  private

  def error_payload(name)
    {
      "schema" => name, "schema_version" => 1, "ok" => false,
      "error_kind" => "usage", "exit_code" => 64, "message" => "bad input"
    }
  end
end
