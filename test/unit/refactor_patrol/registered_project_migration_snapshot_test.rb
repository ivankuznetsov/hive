require "test_helper"
require "hive/refactor_patrol/registered_project_migration_coordinator"

class RefactorPatrolRegisteredProjectMigrationSnapshotTest < Minitest::Test
  include HiveTestHelper

  NullWriterFence = Data.define do
    def assert_quiescent! = true
  end

  def test_failure_after_snapshot_creation_reports_the_verified_snapshot_id
    with_tmp_dir do |project_root|
      state = File.join(project_root, ".hive-state")
      source = File.expand_path(
        "../../fixtures/refactor_patrol/released_v2_job.json", __dir__
      )
      job = File.join(
        state, "refactor_patrol", "v2", "jobs", "job-released.json"
      )
      FileUtils.mkdir_p(File.dirname(job))
      File.binwrite(job, File.binread(source))
      entry = {
        "name" => "demo",
        "project_id" => "project-demo",
        "path" => project_root,
        "real_path" => File.realpath(project_root),
        "hive_state_path" => state
      }
      failing_validator = Object.new
      failing_validator.define_singleton_method(:validate_job!) do |*, **|
        raise RuntimeError, "injected post-snapshot conversion failure"
      end

      result =
        Hive::RefactorPatrol::RegisteredProjectMigrationCoordinator.new(
          registry: -> { [ entry ] },
          project_migrator: lambda do |identity, ownership:|
            Hive::RefactorPatrol::JobStore.migrate_schema!(
              identity.fetch(:real_path),
              hive_state_path: identity.fetch(:hive_state_path),
              project: identity.fetch(:entry),
              ownership: ownership,
              validator: failing_validator,
              writer_fence: NullWriterFence.new
            )
          end,
          status_store: nil
        ).run.fetch(0)

      manifest = JSON.parse(File.binread(File.join(
        state, "refactor_patrol", "v3",
        "job-schema-v2-backup", "manifest.json"
      )))
      assert_equal :failed, result.status
      assert_match(/post-snapshot conversion failure/, result.error)
      assert_equal manifest.fetch("snapshot_id"), result.snapshot_id
    end
  end
end
