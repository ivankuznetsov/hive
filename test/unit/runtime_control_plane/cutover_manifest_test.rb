require "test_helper"
require "fileutils"
require "hive/runtime_control_plane/cutover_manifest"

class RuntimeControlPlaneCutoverManifestTest < Minitest::Test
  include HiveTestHelper

  def test_document_normalizes_identity_and_cutover_evidence
    with_tmp_dir do
      manifest = Hive::RuntimeControlPlane::CutoverManifest.build(
        phase: "ready", installation_id: "install-1", lineage_id: "lineage-1",
        source_release: "0.7.2", target_release: "candidate",
        exclusions: [ { "project_id" => "retired", "reason" => "deregistered" } ],
        task_authority: [ { "task_id" => "task-1", "fingerprint" => "abc" } ],
        evidence: { "activation_epoch" => 20260829120000 }
      )

      assert_equal "install-1", manifest.fetch("installation_id")
      assert_equal "retired", manifest.fetch("exclusions").first.fetch("project_id")
      assert_equal 20260829120000, manifest.dig("evidence", "activation_epoch")
    end
  end

  def test_publish_is_immutable_and_detects_truncation
    with_tmp_dir do |root|
      path = File.join(root, "cutover.json")
      store = Hive::RuntimeControlPlane::CutoverManifest.new(path: path)
      document = minimal_document
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

  def test_failed_publication_never_exposes_partial_manifest
    with_tmp_dir do |root|
      path = File.join(root, "cutover.json")
      store = Hive::RuntimeControlPlane::CutoverManifest.new(
        path: path, before_publish: ->(_temp) { raise Errno::ENOSPC, "full" }
      )
      error = assert_raises(Hive::RuntimeControlPlane::CutoverManifest::PublicationError) do
        store.publish(minimal_document)
      end
      assert_equal :publication_failed, error.code
      refute_path_exists path
      assert_empty Dir.glob("#{path}.tmp-*")
    end
  end

  private

  def minimal_document
    Hive::RuntimeControlPlane::CutoverManifest.build(
      phase: "ready", installation_id: "install-1", lineage_id: "lineage-1",
      source_release: "0.7.2", target_release: "candidate",
      exclusions: [], task_authority: []
    )
  end
end
