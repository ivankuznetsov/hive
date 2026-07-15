require "test_helper"
require "hive/honeycomb/manifest"

class HoneycombManifestTest < Minitest::Test
  def test_parses_inventory_and_computes_canonical_digest
    files = {
      "workflow.yml" => "a" * 64,
      "instructions/work.md" => "b" * 64
    }
    manifest = Hive::Honeycomb::Manifest.load(manifest_yaml(files))

    assert_equal files, manifest.files
    assert_match(/\A[0-9a-f]{64}\z/, manifest.package_digest)
    assert_equal manifest.package_digest,
                 Hive::Honeycomb::Manifest.package_digest(files.reverse_each.to_h)
  end

  def test_rejects_unsafe_duplicate_and_invalid_inventory_paths
    invalid_paths = [ "", ".", "..", "/abs", "a/../b", "a//b", "a\\b", "./a", "a/", "a\0b" ]
    invalid_paths.each do |path|
      error = assert_raises(Hive::Honeycomb::ManifestError) do
        Hive::Honeycomb::Manifest.load(manifest_yaml("workflow.yml" => "a" * 64, path => "b" * 64))
      end
      assert_includes error.message, "path"
    end

    assert_raises(Hive::Honeycomb::ManifestError) do
      Hive::Honeycomb::Manifest.load(manifest_yaml("manifest.yml" => "a" * 64, "workflow.yml" => "b" * 64))
    end
    assert_raises(Hive::Honeycomb::ManifestError) do
      Hive::Honeycomb::Manifest.load(manifest_yaml("asset.bin" => "a" * 64))
    end
  end

  def test_rejects_bad_hash_unknown_keys_and_permission_shapes
    assert_raises(Hive::Honeycomb::ManifestError) { Hive::Honeycomb::Manifest.load("broken: [\n") }

    assert_raises(Hive::Honeycomb::ManifestError) do
      Hive::Honeycomb::Manifest.load(manifest_yaml("workflow.yml" => "nope"))
    end

    data = YAML.safe_load(manifest_yaml("workflow.yml" => "a" * 64))
    data["extra"] = true
    assert_raises(Hive::Honeycomb::ManifestError) { Hive::Honeycomb::Manifest.load(data.to_yaml) }

    data.delete("extra")
    data["permissions"] = { "bash" => "yes" }
    assert_raises(Hive::Honeycomb::ManifestError) { Hive::Honeycomb::Manifest.load(data.to_yaml) }

    data["permissions"] = { "presets" => [ "unknown" ] }
    assert_raises(Hive::Honeycomb::ManifestError) { Hive::Honeycomb::Manifest.load(data.to_yaml) }

    data["permissions"] = { "tools" => [ nil ] }
    assert_raises(Hive::Honeycomb::ManifestError) { Hive::Honeycomb::Manifest.load(data.to_yaml) }
  end

  def test_normalize_path_rejects_unicode_changes_and_normalization_errors
    decomposed = "instructions/cafe\u0301.md"
    assert_raises(Hive::Honeycomb::ManifestError) do
      Hive::Honeycomb::Manifest.normalize_path(decomposed)
    end

    broken = Class.new(String) do
      def unicode_normalize(*) = raise(ArgumentError, "bad normalization")
    end.new("workflow.yml")
    error = assert_raises(Hive::Honeycomb::ManifestError) do
      Hive::Honeycomb::Manifest.normalize_path(broken)
    end
    assert_includes error.message, "bad normalization"
  end

  private

  def manifest_yaml(files)
    {
      "version" => 1,
      "files" => files,
      "permissions" => {
        "presets" => [ "scoped" ],
        "tools" => %w[Read Bash],
        "dirs" => [ "../shared" ],
        "bash" => true,
        "yolo" => false
      }
    }.to_yaml
  end
end
