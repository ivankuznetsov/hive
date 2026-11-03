require "test_helper"
require "hive/workflow_package/canonical_yaml"
require_relative "../../support/canonical_manifest_helpers"

class WorkflowPackageCanonicalYAMLTest < Minitest::Test
  include CanonicalManifestHelpers

  def test_established_canonical_fixtures_reemit_exact_bytes
    %w[canonical canonical_with_recommendations].each do |name|
      bytes = manifest_fixture(name)
      document = YAML.safe_load(bytes)
      assert_equal bytes, Hive::WorkflowPackage::CanonicalYAML.dump_manifest(document)
      assert_equal document.fetch("release_sha256"), Digest::SHA256.hexdigest(
        Hive::WorkflowPackage::CanonicalYAML.dump_manifest(document, include_release: false)
      )
    end
  end

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
