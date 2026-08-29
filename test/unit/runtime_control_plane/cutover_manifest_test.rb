require "test_helper"
require "fileutils"
require "hive/runtime_control_plane/cutover_manifest"

class RuntimeControlPlaneCutoverManifestTest < Minitest::Test
  include HiveTestHelper

  def test_complete_recovery_inventory_preserves_path_type_mode_and_identity
    with_tmp_dir do |root|
      source = File.join(root, "legacy")
      FileUtils.mkdir_p(source, mode: 0o700)
      file = File.join(source, "state.json")
      File.binwrite(file, "{}\n")
      File.chmod(0o600, file)
      manifest = Hive::RuntimeControlPlane::CutoverManifest.build(
        phase: "preparing", installation_id: "install-1", lineage_id: "lineage-1",
        source_release: "0.7.2", target_release: "candidate",
        roots: { "state_home" => source }, required_absences: [ "runtime-control-plane.sqlite3" ],
        exclusions: [ { "project_id" => "retired", "reason" => "deregistered" } ],
        task_authority: [ { "task_id" => "task-1", "fingerprint" => "abc" } ],
        payloads: [ { "sha256" => "a" * 64, "size" => 12 } ]
      )

      directory = manifest.fetch("inventory").find { |entry| entry.fetch("relative_path") == "." }
      entry = manifest.fetch("inventory").find { |item| item.fetch("relative_path") == "state.json" }
      assert_equal "directory", directory.fetch("type")
      assert_equal source, directory.fetch("root_path")
      assert_equal "0700", directory.fetch("mode")
      assert_equal "file", entry.fetch("type")
      assert_equal "0600", entry.fetch("mode")
      assert_equal Digest::SHA256.hexdigest("{}\n"), entry.fetch("sha256")
      assert_equal [ "runtime-control-plane.sqlite3" ], manifest.fetch("required_absences")
      assert_equal "retired", manifest.fetch("exclusions").first.fetch("project_id")
    end
  end

  def test_publish_is_immutable_and_detects_truncation
    with_tmp_dir do |root|
      path = File.join(root, "cutover.json")
      store = Hive::RuntimeControlPlane::CutoverManifest.new(path: path)
      document = minimal_document(root)
      envelope = store.publish(document)

      assert_equal envelope, store.load
      error = assert_raises(Hive::RuntimeControlPlane::CutoverManifest::PublicationError) do
        store.publish(document.merge("phase" => "ready"))
      end
      assert_equal :already_published, error.code

      File.binwrite(path, File.binread(path).byteslice(0, 20))
      error = assert_raises(Hive::RuntimeControlPlane::CutoverManifest::IntegrityError) { store.load }
      assert_equal :manifest_corrupt, error.code
    end
  end

  def test_symlink_hardlink_and_source_mutation_are_rejected
    with_tmp_dir do |root|
      source = File.join(root, "legacy")
      FileUtils.mkdir_p(source)
      target = File.join(source, "target")
      File.binwrite(target, "state")
      File.symlink(target, File.join(source, "linked"))
      assert_raises(Hive::RuntimeControlPlane::CutoverManifest::InventoryError) do
        Hive::RuntimeControlPlane::CutoverManifest.inventory("state" => source)
      end
      File.unlink(File.join(source, "linked"))
      File.link(target, File.join(source, "hard"))
      error = assert_raises(Hive::RuntimeControlPlane::CutoverManifest::InventoryError) do
        Hive::RuntimeControlPlane::CutoverManifest.inventory("state" => source)
      end
      assert_equal :hardlink, error.code
    end
  end

  def test_failed_publication_never_exposes_partial_manifest
    with_tmp_dir do |root|
      path = File.join(root, "cutover.json")
      store = Hive::RuntimeControlPlane::CutoverManifest.new(
        path: path, before_publish: ->(_temp) { raise Errno::ENOSPC, "full" }
      )
      error = assert_raises(Hive::RuntimeControlPlane::CutoverManifest::PublicationError) do
        store.publish(minimal_document(root))
      end
      assert_equal :publication_failed, error.code
      refute_path_exists path
      assert_empty Dir.glob("#{path}.tmp-*")
    end
  end

  private

  def minimal_document(root)
    Hive::RuntimeControlPlane::CutoverManifest.build(
      phase: "preparing", installation_id: "install-1", lineage_id: "lineage-1",
      source_release: "0.7.2", target_release: "candidate", roots: { "state" => root },
      required_absences: [], exclusions: [], task_authority: [], payloads: []
    )
  end
end
