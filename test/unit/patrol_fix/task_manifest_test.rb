require "test_helper"
require "digest"
require "json_schemer"
require "pathname"
require "tmpdir"
require "hive/patrol_fix/task_manifest"

class PatrolFixTaskManifestTest < Minitest::Test
  def test_round_trips_a_strict_bounded_manifest_and_allows_equivalent_provenance
    Dir.mktmpdir do |dir|
      store = Hive::PatrolFix::TaskManifest.new(task_folder: dir)
      first = manifest

      store.write!(first)
      read = store.read

      assert_equal first, read
      assert JSONSchemer.schema(
        Pathname.new(Hive::Schemas.schema_path("hive-patrol-fix-task-manifest"))
      ).valid?(read)
      assert read.frozen?
      assert read.fetch("sources").frozen?

      equivalent = Marshal.load(Marshal.dump(first))
      equivalent["sources"] << source(
        engine: "architecture_patrol", identity: "thesis-7", discovery_run: "architecture-run-2",
        target_revision: "2" * 40
      )
      equivalent["aliases"] << { "kind" => "legacy_issue", "value" => "https://github.com/acme/demo/issues/7" }

      store.write!(equivalent)
      assert_equal 2, store.read.fetch("sources").length
      assert_equal [ "1" * 40, "2" * 40 ], store.read.fetch("sources").map { |entry| entry.fetch("target_revision") }
    end
  end

  def test_materially_changed_digest_requires_the_next_generation
    Dir.mktmpdir do |dir|
      store = Hive::PatrolFix::TaskManifest.new(task_folder: dir)
      store.write!(manifest)

      changed = Marshal.load(Marshal.dump(manifest))
      changed.fetch("evidence_revision")["digest"] = "b" * 64

      error = assert_raises(Hive::PatrolFix::TaskManifest::InvalidManifest) do
        store.write!(changed)
      end
      assert_includes error.message, "generation"

      changed.fetch("evidence_revision")["generation"] = 2
      changed.fetch("task")["generation"] = 2
      store.write!(changed)
      assert_equal 2, store.read.dig("evidence_revision", "generation")
    end
  end

  def test_existing_source_bytes_are_immutable_within_one_evidence_generation
    Dir.mktmpdir do |dir|
      store = Hive::PatrolFix::TaskManifest.new(task_folder: dir)
      store.write!(manifest)

      changed = Marshal.load(Marshal.dump(manifest))
      changed.fetch("sources").first["target_revision"] = "2" * 40

      error = assert_raises(Hive::PatrolFix::TaskManifest::InvalidManifest) do
        store.write!(changed)
      end
      assert_includes error.message, "source provenance"
    end
  end

  def test_unknown_version_oversized_and_symlinked_manifests_fail_closed
    Dir.mktmpdir do |dir|
      store = Hive::PatrolFix::TaskManifest.new(task_folder: dir)
      File.write(store.path, JSON.generate(manifest.merge("schema_version" => 99)))
      assert_raises(Hive::PatrolFix::TaskManifest::InvalidManifest) { store.read }

      File.write(store.path, "{" + ("x" * Hive::PatrolFix::TaskManifest::MAX_BYTES) + "}")
      error = assert_raises(Hive::PatrolFix::TaskManifest::InvalidManifest) { store.read }
      assert_includes error.message, "size limit"

      File.delete(store.path)
      target = File.join(dir, "outside.json")
      File.write(target, JSON.generate(manifest))
      File.symlink(target, store.path)
      error = assert_raises(Hive::PatrolFix::TaskManifest::InvalidManifest) { store.read }
      assert_includes error.message, "symlink"
    end
  end

  def test_manifest_rejects_unknown_fields_and_dependency_as_provenance
    Dir.mktmpdir do |dir|
      store = Hive::PatrolFix::TaskManifest.new(task_folder: dir)

      assert_raises(Hive::PatrolFix::TaskManifest::InvalidManifest) do
        store.write!(manifest.merge("depends_on" => "coding-task"))
      end

      malformed = Marshal.load(Marshal.dump(manifest))
      malformed.fetch("sources").first["prompt"] = "raw model input"
      assert_raises(Hive::PatrolFix::TaskManifest::InvalidManifest) do
        store.write!(malformed)
      end
    end
  end

  def test_rejects_missing_fields_generation_leaps_and_missing_files
    Dir.mktmpdir do |dir|
      store = Hive::PatrolFix::TaskManifest.new(task_folder: dir)
      error = assert_raises(Hive::PatrolFix::TaskManifest::InvalidManifest) { store.read }
      assert_includes error.message, "missing"

      assert_raises(Hive::PatrolFix::TaskManifest::InvalidManifest) do
        store.write!(manifest.reject { |key, _| key == "relations" })
      end

      store.write!(manifest)
      leap = Marshal.load(Marshal.dump(manifest))
      leap.fetch("task")["generation"] = 3
      leap.fetch("evidence_revision").merge!("generation" => 3, "digest" => "b" * 64)
      assert_raises(Hive::PatrolFix::TaskManifest::InvalidManifest) { store.write!(leap) }
    end
  end

  def test_translates_manifest_io_and_serialization_failures
    Dir.mktmpdir do |dir|
      store = Hive::PatrolFix::TaskManifest.new(task_folder: dir)
      File.write(store.path, Hive::PatrolFix.canonical_json(manifest))

      [ Errno::ELOOP.new("loop"), IOError.new("closed") ].each do |failure|
        original = File.method(:open)
        File.define_singleton_method(:open, ->(*) { raise failure })
        begin
          assert_raises(Hive::PatrolFix::TaskManifest::InvalidManifest) { store.read }
        ensure
          File.define_singleton_method(:open, original)
        end
      end

      original = Hive::PatrolFix.method(:canonical_json)
      Hive::PatrolFix.define_singleton_method(:canonical_json, ->(*) { raise JSON::GeneratorError, "bad value" })
      begin
        assert_raises(Hive::PatrolFix::TaskManifest::InvalidManifest) do
          store.write!(manifest)
        end
      ensure
        Hive::PatrolFix.define_singleton_method(:canonical_json, original)
      end
    end
  end

  private

  def manifest
    {
      "schema" => "hive-patrol-fix-task-manifest",
      "schema_version" => 1,
      "task" => { "slug" => "repair-login-260820-abcd", "generation" => 1 },
      "evidence_revision" => { "generation" => 1, "digest" => "a" * 64 },
      "target_revision" => "1" * 40,
      "sources" => [ source ],
      "aliases" => [],
      "relations" => { "successor" => nil, "issues" => [] }
    }
  end

  def source(engine: "ordinary_patrol", identity: "finding-1", discovery_run: "ordinary-run-1",
             target_revision: "1" * 40)
    {
      "engine" => engine,
      "identity" => identity,
      "target_revision" => target_revision,
      "evidence" => [ "The failing branch is reachable from request handling." ],
      "affected_code" => [ "lib/demo.rb" ],
      "reproduction_guidance" => "Run the focused request test with the stale token fixture.",
      "discovery_run" => discovery_run,
      "semantic_lineage" => [ "root-login-refresh" ]
    }
  end
end
