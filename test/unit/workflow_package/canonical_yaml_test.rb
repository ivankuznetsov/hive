require "test_helper"
require "hive/workflow_package/canonical_yaml"

class WorkflowPackageCanonicalYAMLTest < Minitest::Test
  def test_encodes_empty_nested_and_scalar_values_deterministically
    serializer = Hive::WorkflowPackage::CanonicalYAML

    assert_equal({ "a" => 1, "b" => 2 }, serializer.ordered_value("x-example", { "b" => 2, "a" => 1 }))
    assert_equal "{}\n", serializer.dump({})
    assert_equal "[]\n", serializer.dump([])
    assert_equal "nested:\n  -\n    - 1\n", serializer.dump({ "nested" => [ [ 1 ] ] })

    {
      1 => "1\n",
      1.5 => "1.5\n",
      true => "true\n",
      false => "false\n",
      nil => "null\n"
    }.each do |value, expected|
      assert_equal expected, serializer.dump(value)
    end
  end

  def test_rejects_non_finite_and_unknown_scalar_values
    serializer = Hive::WorkflowPackage::CanonicalYAML

    assert_raises(ArgumentError) { serializer.dump(Float::INFINITY) }
    assert_raises(ArgumentError) { serializer.dump(Object.new) }
  end
end
