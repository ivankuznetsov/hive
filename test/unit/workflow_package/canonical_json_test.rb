require "test_helper"
require "hive/workflow_package/canonical_json"

class WorkflowPackageCanonicalJSONTest < Minitest::Test
  def test_parses_and_normalizes_supported_scalar_types
    json = Hive::WorkflowPackage::CanonicalJSON.generate(symbol: :value, number: 1.5)

    assert_equal({ "number" => 1.5, "symbol" => "value" }, Hive::WorkflowPackage::CanonicalJSON.parse(json))
  end

  def test_rejects_non_finite_unknown_and_invalidly_encoded_values
    assert_raises(ArgumentError) { Hive::WorkflowPackage::CanonicalJSON.generate(Float::INFINITY) }
    assert_raises(ArgumentError) { Hive::WorkflowPackage::CanonicalJSON.generate(Object.new) }
    invalid = "\xFF".b
    assert_raises(ArgumentError) { Hive::WorkflowPackage::CanonicalJSON.generate(invalid) }
  end
end
