require_relative "../../test_helper"
require_relative "schemas"
require_relative "paths"

# Schema-name drift guard: every "schema" => "hive-e2e-..." literal that
# appears in an e2e producer (runner.rb, artifact_capture.rb, bin/hive-e2e)
# must be registered in Hive::E2E::Schemas::VERSIONS. Without this, a
# typo in a producer (`hive-e2e-mainfest` instead of `hive-e2e-manifest`)
# would slip through into agent-readable output silently.
class E2ESchemasTest < Minitest::Test
  PRODUCER_FILES = [
    File.join(Hive::E2E::Paths.repo_root, "bin", "hive-e2e"),
    File.join(Hive::E2E::Paths.e2e_root, "lib", "runner.rb"),
    File.join(Hive::E2E::Paths.e2e_root, "lib", "artifact_capture.rb")
  ].freeze

  def test_versions_registry_is_frozen
    assert_predicate Hive::E2E::Schemas::VERSIONS, :frozen?,
                     "VERSIONS must be frozen so producers cannot mutate it at load time"
  end

  def test_version_for_raises_on_unknown_schema
    assert_raises(KeyError) { Hive::E2E::Schemas.version_for("hive-e2e-not-a-real-schema") }
  end

  def test_every_emitted_schema_name_is_registered
    emitted = PRODUCER_FILES.flat_map do |path|
      File.read(path).scan(/"schema"\s*=>\s*"(hive-e2e-[a-z0-9-]+)"/).flatten
    end.uniq.sort

    refute_empty emitted, "expected to find at least one hive-e2e-* schema literal in the producers"

    registered = Hive::E2E::Schemas::VERSIONS.keys.sort
    unregistered = emitted - registered
    assert_empty unregistered,
                 "the following hive-e2e-* schema names are emitted by producers but not registered in " \
                 "test/e2e/lib/schemas.rb: #{unregistered.inspect}"
  end

  def test_no_registered_schema_is_unused
    emitted = PRODUCER_FILES.flat_map do |path|
      File.read(path).scan(/"schema"\s*=>\s*"(hive-e2e-[a-z0-9-]+)"/).flatten
    end.uniq

    unused = Hive::E2E::Schemas::VERSIONS.keys - emitted
    assert_empty unused,
                 "the following registered schemas have no producer emitting them — either delete them " \
                 "or wire them into a producer: #{unused.inspect}"
  end

  def test_versions_are_positive_integers
    Hive::E2E::Schemas::VERSIONS.each do |name, version|
      assert_kind_of Integer, version, "#{name.inspect} version must be an Integer"
      assert_operator version, :>=, 1, "#{name.inspect} version must be >= 1"
    end
  end

  def test_every_registered_schema_has_a_published_file
    Hive::E2E::Schemas::VERSIONS.each_key do |name|
      path = Hive::E2E::Schemas.schema_path(name)
      assert File.exist?(path), "published schema file missing: #{path}"
    end
  end
end
