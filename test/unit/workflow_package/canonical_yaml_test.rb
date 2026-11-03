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
  def test_manifest_roles_preserve_known_order_and_every_lexical_remainder
    document = {
      "z" => 1, "schema" => "example", "a" => 2,
      "author" => { "z" => 1, "url" => "url", "name" => "name", "a" => 2 },
      "source" => { "z" => 1, "revision" => "rev", "url" => "url", "a" => 2 },
      "permissions" => { "z" => 1, "secrets" => [], "risk" => "low", "a" => 2 },
      "files" => { "z" => { "z" => 1, "a" => 2 }, "a" => "hash" },
      "x-hive" => {
        "z" => 1, "a" => 2, "external_skills" => [ "skill" ],
        "mapping_recommendations" => [ { "z" => 1, "effort" => "high", "slot" => "work", "a" => 2 } ],
        "optional_inputs" => [ { "z" => 1, "authorized_slots" => [ "work" ], "name" => "INPUT", "a" => 2 } ],
        "prompt_assets" => [ { "z" => 1, "path" => "prompt", "a" => 2 } ],
        "tools" => [ { "z" => 1, "path" => "tool", "a" => 2 } ]
      }
    }
    actual = YAML.safe_load(Hive::WorkflowPackage::CanonicalYAML.dump_manifest(document))
    assert_equal document, actual
    assert_equal %w[schema author source permissions files a x-hive z], actual.keys
    assert_equal %w[name url a z], actual.fetch("author").keys
    assert_equal %w[url revision a z], actual.fetch("source").keys
    assert_equal %w[risk secrets a z], actual.fetch("permissions").keys
    assert_equal %w[a z], actual.fetch("files").keys
    hive = actual.fetch("x-hive")
    assert_equal %w[tools prompt_assets optional_inputs external_skills mapping_recommendations a z], hive.keys
    assert_equal %w[name authorized_slots a z], hive.fetch("optional_inputs").first.keys
    assert_equal %w[slot effort a z], hive.fetch("mapping_recommendations").first.keys
    %w[tools prompt_assets].each { |key| assert_equal %w[path a z], hive.fetch(key).first.keys }
  end

  def test_reserved_names_at_arbitrary_extension_depths_stay_generic
    collisions = %w[author source permissions files x-hive].to_h do |name|
      [ name, { "z" => 2, "custom" => "must-survive", "a" => 1 } ]
    end
    document = { "x-meta" => collisions }
    5.times do
      bytes = Hive::WorkflowPackage::CanonicalYAML.dump_manifest(document)
      assert_equal document, YAML.safe_load(bytes)
      expected = deep_sort(document)
      assert_equal Hive::WorkflowPackage::CanonicalYAML.dump(expected), bytes
      document = { "x-meta" => { "wrapper" => [ document, collisions ] } }
    end
  end

  def test_recursive_permutations_are_idempotent_without_mutating_input
    document = YAML.safe_load(manifest_fixture("canonical"))
    document["x-meta"] = { "z" => { "permissions" => { "z" => 2, "a" => 1 } }, "a" => [ { "z" => 2, "a" => 1 } ] }
    before = Marshal.load(Marshal.dump(document))
    reversed = reverse_maps(document)
    bytes = Hive::WorkflowPackage::CanonicalYAML.dump_manifest(document)
    assert_equal bytes, Hive::WorkflowPackage::CanonicalYAML.dump_manifest(reversed)
    assert_equal bytes, Hive::WorkflowPackage::CanonicalYAML.dump_manifest(YAML.safe_load(bytes))
    assert_equal bytes, Hive::WorkflowPackage::CanonicalYAML.dump_manifest(document)
    assert_equal before, document
    assert_equal reverse_maps(before), reversed
  end

  def test_sequences_and_ambiguous_schema_paths_preserve_positions_and_values
    values = [ "text", 3, 1.5, true, false, nil, {}, [], { "z" => 2, "author" => { "z" => 2, "a" => 1 }, "a" => 1 }, [ { "z" => 2, "a" => 1 } ] ]
    document = { "author" => values, "x-hive" => { "optional_inputs" => [ [ { "name" => "x", "authorized_slots" => [] } ] ] } }
    bytes = Hive::WorkflowPackage::CanonicalYAML.dump_manifest(document)
    actual = YAML.safe_load(bytes)
    assert_equal document, actual
    assert_equal %w[a author z], actual.fetch("author")[8].keys
    assert_equal %w[authorized_slots name], actual.dig("x-hive", "optional_inputs", 0, 0).keys
  end

  def test_unsigned_dump_omits_only_the_root_release_field
    document = { "release_sha256" => "root", "x-meta" => { "release_sha256" => "nested" } }
    bytes = Hive::WorkflowPackage::CanonicalYAML.dump_manifest(document, include_release: false)
    assert_equal({ "x-meta" => { "release_sha256" => "nested" } }, YAML.safe_load(bytes))
    document["x-meta"]["release_sha256"] = "changed"
    refute_equal bytes, Hive::WorkflowPackage::CanonicalYAML.dump_manifest(document, include_release: false)
  end

  def test_manifest_keys_fail_uniformly_before_sorting_at_every_depth
    [ { 1 => "bad", "a" => 1 }, { "author" => { "name" => "ok", 1 => "bad" } },
      { "x-meta" => [ { "a" => 1, nil => "bad" } ] } ].each do |document|
      error = assert_raises(ArgumentError) { Hive::WorkflowPackage::CanonicalYAML.dump_manifest(document) }
      assert_equal "canonical YAML keys must be strings", error.message
    end
    [ Float::INFINITY, Float::NAN, Object.new ].each do |value|
      assert_raises(ArgumentError) { Hive::WorkflowPackage::CanonicalYAML.dump_manifest({ "x-meta" => value }) }
    end
    refute_respond_to Hive::WorkflowPackage::CanonicalYAML, :ordered_value
  end

  private

  def deep_sort(value)
    case value
    when Hash then value.sort.to_h.transform_values { |child| deep_sort(child) }
    when Array then value.map { |child| deep_sort(child) }
    else value
    end
  end

  def reverse_maps(value)
    case value
    when Hash then value.to_a.reverse.to_h.transform_values { |child| reverse_maps(child) }
    when Array then value.map { |child| reverse_maps(child) }
    else value
    end
  end
end
