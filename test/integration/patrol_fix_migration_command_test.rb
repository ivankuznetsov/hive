require "test_helper"
require "hive/commands/init"
require "hive/commands/module/migration"
require "hive/daemon/patrol_fix_runtime"
require "hive/modules/migration/patrol_fix_cutover"
require "open3"

class PatrolFixMigrationCommandTest < Minitest::Test
  include HiveTestHelper

  def test_preflight_output_applies_and_daemon_reconstructs_committed_sources_and_factories
    with_tmp_global_config do
      with_tmp_git_repo do |project|
        capture_io { Hive::Commands::Init.new(project, agent_skill_preflight: false).call }
        entry = {
          "name" => "demo", "path" => project,
          "hive_state_path" => File.join(project, ".hive-state")
        }

        preflight_output = StringIO.new
        Hive::Commands::Module::Migration.new(
          "patrol-fix-preflight", project_root: project, json: true, stdout: preflight_output,
          stdin: StringIO.new(JSON.generate("semantic_decisions" => []))
        ).call
        request = JSON.parse(preflight_output.string)

        apply_output = StringIO.new
        result = Hive::Commands::Module::Migration.new(
          "patrol-fix-apply", project_root: project, json: true, stdout: apply_output,
          stdin: StringIO.new(JSON.generate(request)), yes: true
        ).call

        assert_equal "committed", result.fetch("status")
        assert_equal "committed", JSON.parse(apply_output.string).fetch("status")
        assert Hive::Patrol::StateStore.new(project).patrol_fix_admission_outbox.enabled?
        assert Hive::RefactorPatrol::JobStore.new(project).patrol_fix_admission_outbox.enabled?

        runtime = Hive::Daemon::PatrolFixRuntime.new(
          registry: -> { [ entry ] },
          decision_runner_factory: ->(**) { ->(_input) { flunk "empty preflight must not run LLM" } }
        )
        assert_equal 2, runtime.sources.length
        assert runtime.sources.all?(&:enabled?)
        source = runtime.sources.first
        store = runtime.admission_store(source: source)
        assert_instance_of Hive::PatrolFix::AdmissionStore, store
        assert_instance_of Hive::PatrolFix::SemanticAdmission,
                           runtime.semantic_admission(store: store, source: source)
        assert_instance_of Hive::PatrolFix::TaskMaterializer,
                           runtime.task_materializer(
                             store: store, source: source,
                             source_acknowledger: ->(*) { "ack" }
                           )
      end
    end
  end

  def test_nonempty_apply_re_reads_source_materializes_task_then_settles_source_ack
    with_tmp_global_config do
      with_tmp_git_repo do |project|
        capture_io { Hive::Commands::Init.new(project, agent_skill_preflight: false).call }
        store = Hive::Patrol::StateStore.new(project)
        store.with_cycle_lock { nil }
        finding = Hive::Patrol::Finding.new(
          id: "finding-1", feature_id: "feature", category: "bug",
          severity: "medium", confidence: "high", title: "Repair refresh",
          description: "Refresh can leave state inconsistent.",
          fingerprint: "refresh-root", target_sha: git_head(project),
          lifecycle_state: "active",
          lifecycle_updated_at: "2026-08-21T00:00:00Z"
        )
        store.write_finding(finding)

        preflight = run_command(
          "patrol-fix-preflight", project,
          request: { "semantic_decisions" => [] }
        )
        applied = run_command(
          "patrol-fix-apply", project, request: preflight, yes: true
        )

        assert_equal "committed", applied.fetch("status")
        group = applied.fetch("groups").values.fetch(0)
        assert_equal "complete", group.fetch("status")
        task = group.fetch("task")
        folders = Dir.glob(File.join(project, ".hive-state", "stages", "*", task.fetch("slug")))
        assert_equal 1, folders.length
        manifest = Hive::PatrolFix::TaskManifest.new(task_folder: folders.first).read
        assert_equal "finding-1", manifest.dig("sources", 0, "identity")

        snapshot = store.patrol_fix_admission_outbox.migration_snapshot(finding)
        occurrence = store.patrol_fix_admission_outbox.migration_occurrence_id(snapshot)
        outbox_record = Hive::Patrol::StateStore.new(project)
                            .patrol_fix_admission_outbox.fetch(occurrence)
        assert_equal "settled", outbox_record.fetch("status")
        assert_equal task, outbox_record.dig("acknowledgement", "task")
        assert_equal group.fetch("acknowledgements").fetch("ordinary_finding:finding-1"),
                     outbox_record.dig("acknowledgement", "receipt_id")
      end
    end
  end

  def test_interrupted_forward_only_apply_resumes_from_the_durable_manifest
    with_tmp_global_config do
      with_tmp_git_repo do |project|
        capture_io { Hive::Commands::Init.new(project, agent_skill_preflight: false).call }
        store = Hive::Patrol::StateStore.new(project)
        store.with_cycle_lock { nil }
        store.write_finding(Hive::Patrol::Finding.new(
          id: "finding-recovery", feature_id: "feature", category: "bug",
          severity: "medium", confidence: "high", title: "Repair recovery",
          description: "Recovery can leave state inconsistent.",
          fingerprint: "recovery-root", target_sha: git_head(project),
          lifecycle_state: "active",
          lifecycle_updated_at: "2026-08-21T00:00:00Z"
        ))
        preflight = run_command(
          "patrol-fix-preflight", project,
          request: { "semantic_decisions" => [] }
        )
        manifest = Hive::PatrolFix::Migration::DispositionManifest.new(
          preflight.fetch("manifest")
        )
        crash_after_effect_arm = Object.new
        crash_after_effect_arm.define_singleton_method(:call) do |_group|
          raise "simulated controller exit after effect arm"
        end
        interrupted = Hive::Modules::Migration::PatrolFixCutover.new(
          project_root: project, hive_state_path: File.join(project, ".hive-state"),
          manifest: manifest, group_materializer: crash_after_effect_arm
        )

        assert_raises(RuntimeError) { interrupted.call }
        state = interrupted.state.read
        assert_equal "applying", state.fetch("status")
        assert state.fetch("new_authority_effect")
        assert_raises(Hive::PatrolFix::Migration::CutoverState::ForwardOnly) do
          interrupted.rollback!
        end

        resumed = run_command(
          "patrol-fix-apply", project, request: nil, yes: true
        )

        assert_equal "committed", resumed.fetch("status")
        assert_equal 1, resumed.fetch("groups").length
        assert_equal 1, Dir.glob(
          File.join(project, ".hive-state", "stages", "*", "*", "patrol-fix-manifest.json")
        ).length
      end
    end
  end

  private

  def run_command(action, project, request:, yes: false)
    output = StringIO.new
    Hive::Commands::Module::Migration.new(
      action, project_root: project, json: true, stdout: output,
      stdin: StringIO.new(request ? JSON.generate(request) : ""), yes: yes
    ).call
    JSON.parse(output.string)
  end

  def git_head(project)
    output, = Open3.capture2("git", "-C", project, "rev-parse", "HEAD")
    output.strip
  end
end
