require "test_helper"
require "hive/commands/init"
require "hive/commands/migrate"

class MigrateTest < Minitest::Test
  include HiveTestHelper

  NoopDisplayNameGenerator = Class.new do
    def initialize(_task, cfg: nil, commit: true); end

    def call
      nil
    end
  end

  RecordingDisplayNameGenerator = Class.new do
    class << self
      attr_accessor :calls
    end
    self.calls = []

    def initialize(task, cfg: nil, commit: true)
      @task = task
      self.class.calls << { slug: task.slug, commit: commit, project: cfg["project_name"] }
    end

    def call
      name = @task.slug.split("-").first(3).map(&:capitalize).join(" ")
      Hive::TaskMeta.update_display_name(@task.folder, name)
      name
    end
  end

  def test_migrates_legacy_stage_directories
    with_tmp_global_config(runtime: false) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        stages = File.join(dir, ".hive-state", "stages")
        {
          "5-review" => "old-review-260513-abcd",
          "6-pr" => "old-pr-260513-abcd",
          "7-done" => "old-done-260513-abcd"
        }.each do |stage, slug|
          folder = File.join(stages, stage, slug)
          FileUtils.mkdir_p(folder)
          File.write(File.join(folder, "task.md"), "x\n")
        end
        legacy_error = File.join(
          stages, "5-review", "old-review-260513-abcd", "task.md"
        )
        File.write(legacy_error, "# Review\n\n<!-- REVIEW_ERROR reason=timeout -->\n")

        restart_calls = 0
        out, _err = capture_io do
          migrate_command(dir, daemon_restarter: -> { restart_calls += 1 }).call
        end

        assert File.directory?(File.join(stages, "6-review", "old-review-260513-abcd"))
        assert File.directory?(File.join(stages, "8-finalize", "old-pr-260513-abcd"))
        assert File.directory?(File.join(stages, "9-done", "old-done-260513-abcd"))
        assert_includes out, "1 recovery marker upgraded"
        assert_equal 1, restart_calls
      end
    end
  end

  def test_runs_the_injected_global_migration_once
    with_tmp_global_config(runtime: false) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        calls = 0

        capture_io do
          migrate_command(dir, global_migration: -> { calls += 1 }).call
        end

        assert_equal 1, calls
      end
    end
  end

  def test_default_migration_refuses_a_missing_or_unactivated_control_plane
    with_tmp_global_config(runtime: false) do |home|
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        error = assert_raises(Hive::RuntimeControlPlane::MigrationRequired) do
          Hive::Commands::Migrate.new(dir).call
        end
        assert_equal :missing_database, error.code
        refute_path_exists Hive::Paths.runtime_control_plane_path(home)

        Hive::RuntimeControlPlane::Database.new(
          path: Hive::Paths.runtime_control_plane_path(home)
        ).migrate!.disconnect
        error = assert_raises(Hive::RuntimeControlPlane::MigrationRequired) do
          Hive::Commands::Migrate.new(dir).call
        end
        assert_equal :control_plane_inactive, error.code
      end
    end
  end

  def test_default_migration_continues_after_fleet_activation
    with_tmp_global_config(runtime: false) do |home|
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        activate_control_plane(home)

        out, = capture_io { Hive::Commands::Migrate.new(dir).call }

        assert_includes out, "hive: migrate"
      end
    end
  end

  def test_class_restart_entrypoint_delegates_to_the_instance_boundary
    called = false
    instance = Object.new
    instance.define_singleton_method(:restart_daemon_if_running!) { called = true }

    with_replaced_singleton_method(Hive::Commands::Migrate, :new, ->(*) { instance }) do
      Hive::Commands::Migrate.restart_daemon_if_running!
    end

    assert called
  end

  def test_healthy_database_without_active_phase_requires_fleet_cutover
    with_tmp_global_config(runtime: false) do |home|
      Hive::RuntimeControlPlane::Database.new(
        path: Hive::Paths.runtime_control_plane_path(home)
      ).migrate!.disconnect
      command = Hive::Commands::Migrate.new(home)

      with_replaced_singleton_method(
        Hive::RuntimeControlPlane::Cutover, :inspect_status,
        ->(**) { { "phase" => "ready" } }
      ) do
        error = assert_raises(Hive::RuntimeControlPlane::MigrationRequired) do
          command.send(:ensure_active_control_plane!)
        end
        assert_equal :control_plane_inactive, error.code
      end
    end
  end

  def test_explicit_migrate_rebuilds_the_patrol_fix_pending_index_once
    with_tmp_global_config(runtime: false) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        root = File.join(dir, ".hive-state", "patrol-fix", "admissions")
        store = Hive::PatrolFix::AdmissionStore.new(root: root)
        store.reserve!(
          occurrence_id: "legacy-admission",
          snapshot: patrol_fix_source_snapshot,
          now: Time.utc(2026, 8, 23, 12)
        )
        File.delete(File.join(root, "pending-index.json"))
        restarts = 0

        first_out, = capture_io do
          migrate_command(
            dir, daemon_restarter: -> { restarts += 1 }, daemon_cutover: -> { false }
          ).call
        end
        second_out, = capture_io do
          migrate_command(
            dir, daemon_restarter: -> { restarts += 1 }, daemon_cutover: -> { false }
          ).call
        end

        assert File.file?(File.join(root, "pending-index.json"))
        assert_includes first_out, "rebuilt Patrol Fix admission index (1 pending of 1 records)"
        refute_includes second_out, "rebuilt Patrol Fix admission index"
        assert_equal 1, restarts
      end
    end
  end

  def test_patrol_index_cutover_restarts_then_rebuilds_once_more
    with_tmp_global_config(runtime: false) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        root = File.join(dir, ".hive-state", "patrol-fix", "admissions")
        store = Hive::PatrolFix::AdmissionStore.new(root: root)
        store.reserve!(
          occurrence_id: "legacy-admission",
          snapshot: patrol_fix_source_snapshot,
          now: Time.utc(2026, 8, 23, 12)
        )
        index_path = File.join(root, "pending-index.json")
        File.delete(index_path)
        cutovers = 0
        restarts = 0

        capture_io do
          migrate_command(
            dir,
            daemon_cutover: lambda {
              cutovers += 1
              File.delete(index_path)
              true
            },
            daemon_restarter: -> { restarts += 1 }
          ).call
        end

        assert_equal 1, cutovers
        assert_equal 0, restarts
        assert File.file?(index_path)
        assert_equal [ "legacy-admission" ],
                     store.pending.map { |record| record.fetch("occurrence_id") }
      end
    end
  end

  def test_backfills_plan_review_requirement_before_execute_but_grandfathers_execute
    with_tmp_global_config(runtime: false) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        stages = File.join(dir, ".hive-state", "stages")
        plan = write_task_folder(stages, "3-plan", "legacy-plan-260812-abcd")
        execute = write_task_folder(
          stages, "4-execute", "legacy-execute-260812-abcd", idea: false
        )
        Hive::TaskMeta.write(
          plan, id: 40, slug: File.basename(plan), display_name: "Legacy plan"
        )
        Hive::TaskMeta.write(
          execute, id: 41, slug: File.basename(execute), display_name: "Legacy execute"
        )

        out, = capture_io do
          migrate_command(dir, daemon_restarter: -> { }).call
        end

        assert Hive::TaskMeta.plan_review_required?(plan)
        refute Hive::TaskMeta.plan_review_required?(execute)
        assert_includes out, "added 1 plan review requirement"
      end
    end
  end

  def test_migrates_attributed_legacy_dirty_execute_wait_once
    with_tmp_global_config(runtime: false) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        stages = File.join(dir, ".hive-state", "stages")
        folder = write_task_folder(
          stages, "4-execute", "legacy-dirty-260821-abcd", idea: false
        )
        Hive::TaskMeta.write(
          folder, id: 42, slug: File.basename(folder), display_name: "Legacy dirty"
        )
        task = Hive::Task.new(folder)
        Hive::Markers.set(
          task.state_file, :execute_waiting,
          reason: "dirty_worktree", attempt_id: "attempt-pi-1"
        )

        out, = capture_io do
          migrate_command(dir, daemon_restarter: -> { }).call
        end

        marker = Hive::Markers.current(task.state_file)
        assert_equal :error, marker.name
        assert_equal "dirty_worktree", marker.attrs.fetch("reason")
        assert_equal "execute_waiting", marker.attrs.fetch("recovered_from")
        assert_equal "attempt-pi-1", marker.attrs.fetch("attempt_id")
        refute_empty marker.attrs.fetch("marker_id")
        assert_includes out, "upgraded 1 recovery marker"

        second_out, = capture_io do
          migrate_command(dir, daemon_restarter: -> { }).call
        end
        assert_includes second_out, "found nothing to move"
      end
    end
  end

  def test_combined_metadata_only_migration_has_a_project_state_commit_message
    message = migrate_command("/tmp/project").send(
      :migrate_commit_message,
      [],
      config_only: false,
      backfilled_count: 2,
      recovery_marker_count: 3,
      workflow_task_count: 4
    )

    assert_equal(
      "hive: migrate project state (2 ids, 3 recovery markers, " \
      "4 managed workflow tasks)",
      message
    )
  end

  def test_managed_workflow_task_only_commit_message
    message = migrate_command("/tmp/project").send(
      :migrate_commit_message,
      [],
      config_only: false,
      workflow_task_count: 1
    )

    assert_equal "hive: migrate managed workflow tasks (1 task)", message
  end

  def test_managed_workflow_task_no_move_message
    message = migrate_command("/tmp/project").send(
      :migration_no_move_message,
      config_changed: false,
      backfilled_count: 0,
      workflow_task_count: 2,
      workflow_moved_count: 1
    )

    assert_equal "hive: migrate migrated 2 managed workflow tasks (1 stage moved)", message
  end

  def test_complete_message_reports_every_migration_count
    message = migrate_command("/tmp/project").send(
      :migration_complete_message,
      [ [ "5-review", "6-review", "task-a" ], [ "6-pr", "8-finalize", "task-b" ] ],
      backfilled_count: 2,
      recovery_marker_count: 3,
      workflow_task_count: 4,
      workflow_moved_count: 2,
      plan_review_requirement_count: 2
    )

    assert_equal(
      "hive: migrate complete (2 tasks moved, 2 ids backfilled, " \
      "3 recovery markers upgraded, 4 managed workflow tasks migrated (2 stages moved), " \
      "2 plan review requirements added)",
      message
    )
  end

  def test_backfills_missing_registered_repository_identity_once
    with_tmp_global_config(runtime: false) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        entry = Hive::Config.registered_projects.find { |project| project["path"] == dir }
        assert_nil entry["repository_identity"]
        run!("git", "-C", dir, "remote", "add", "origin", "https://github.com/acme/demo.git")

        out, = capture_io { migrate_command(dir).call }

        migrated = Hive::Config.registered_projects.find { |project| project["path"] == dir }
        assert_equal "github.com/acme/demo", migrated["repository_identity"]
        assert_includes out, "backfilled registered repository identity github.com/acme/demo"

        run!("git", "-C", dir, "remote", "set-url", "origin", "https://github.com/acme/other.git")
        second_out, = capture_io { migrate_command(dir).call }
        preserved = Hive::Config.registered_projects.find { |project| project["path"] == dir }
        assert_equal "github.com/acme/demo", preserved["repository_identity"]
        refute_includes second_out, "backfilled registered repository identity"
      end
    end
  end

  def test_registered_project_path_comparison_fails_closed_for_missing_paths
    with_tmp_dir do |dir|
      refute migrate_command(dir).send(
        :same_project_path?,
        File.join(dir, "missing-candidate"),
        File.join(dir, "missing-expected")
      )
    end
  end

  def test_migrates_previous_canonical_finalize_and_done_stage_directories
    with_tmp_global_config(runtime: false) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        stages = File.join(dir, ".hive-state", "stages")
        {
          "7-finalize" => "old-finalize-260522-abcd",
          "8-done" => "old-done-260522-abcd"
        }.each do |stage, slug|
          folder = File.join(stages, stage, slug)
          FileUtils.mkdir_p(folder)
          File.write(File.join(folder, "task.md"), "x\n")
        end

        capture_io { migrate_command(dir).call }

        assert File.directory?(File.join(stages, "8-finalize", "old-finalize-260522-abcd"))
        assert File.directory?(File.join(stages, "9-done", "old-done-260522-abcd"))
      end
    end
  end

  def test_migrate_refuses_conflicting_slug
    with_tmp_global_config(runtime: false) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        stages = File.join(dir, ".hive-state", "stages")
        old = File.join(stages, "5-review", "same-260513-abcd")
        current = File.join(stages, "6-review", "same-260513-abcd")
        FileUtils.mkdir_p(old)
        FileUtils.mkdir_p(current)

        assert_raises(Hive::DestinationCollision) do
          capture_io { migrate_command(dir).call }
        end
        assert File.directory?(old)
        assert File.directory?(current)
      end
    end
  end

  def test_migrate_preflight_catches_plan_internal_duplicate_destination
    with_tmp_global_config(runtime: false) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        stages = File.join(dir, ".hive-state", "stages")
        slug = "same-finalize-260525-aaaa"
        FileUtils.mkdir_p(File.join(stages, "6-pr", slug))
        FileUtils.mkdir_p(File.join(stages, "7-finalize", slug))

        err = assert_raises(Hive::DestinationCollision) do
          capture_io { migrate_command(dir).call }
        end

        assert_match(/multiple legacy stages target the same destination/, err.message)
        assert File.directory?(File.join(stages, "6-pr", slug))
        assert File.directory?(File.join(stages, "7-finalize", slug))
        refute File.directory?(File.join(stages, "8-finalize", slug)),
               "plan-internal duplicate destinations must abort before any mv"
      end
    end
  end

  # Mid-loop atomicity (round-1 finding): pre-flight collision check
  # must catch a SECOND-iteration collision BEFORE the first-iteration
  # rename runs. Without this, a successful 5-review→6-review followed
  # by a 6-pr→8-finalize collision would leave the filesystem partially
  # renamed with no rollback.
  def test_migrate_preflight_catches_later_collision_before_first_mv
    with_tmp_global_config(runtime: false) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        stages = File.join(dir, ".hive-state", "stages")
        review_slug = "review-260513-aaaa"
        pr_slug = "pr-260513-bbbb"
        # Set up a clean 5-review→6-review path (would succeed alone)
        FileUtils.mkdir_p(File.join(stages, "5-review", review_slug))
        # And a 6-pr→8-finalize collision (destination exists).
        FileUtils.mkdir_p(File.join(stages, "6-pr", pr_slug))
        FileUtils.mkdir_p(File.join(stages, "8-finalize", pr_slug))

        assert_raises(Hive::DestinationCollision) do
          capture_io { migrate_command(dir).call }
        end

        # CRITICAL: the first-iteration rename must NOT have run.
        # If pre-flight is broken, 5-review/review-... would be gone.
        assert File.directory?(File.join(stages, "5-review", review_slug)),
               "pre-flight must catch later-iteration collisions BEFORE issuing any mv"
        refute File.directory?(File.join(stages, "6-review", review_slug)),
               "first-iteration destination must NOT exist after pre-flight failure"
      end
    end
  end

  # Skip non-slug entries (round-1 finding): only task-folder slugs
  # should migrate. `.DS_Store`, stray `.lock`, etc. must stay put.
  def test_migrate_skips_non_slug_entries
    with_tmp_global_config(runtime: false) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        stages = File.join(dir, ".hive-state", "stages")
        FileUtils.mkdir_p(File.join(stages, "5-review", ".DS_Store"))
        FileUtils.mkdir_p(File.join(stages, "5-review", "real-260513-aaaa"))

        capture_io { migrate_command(dir).call }

        assert File.directory?(File.join(stages, "5-review", ".DS_Store")),
               "non-slug `.DS_Store` directory must stay in the legacy stage dir"
        assert File.directory?(File.join(stages, "6-review", "real-260513-aaaa")),
               "task slug must migrate normally"
      end
    end
  end

  def test_migrate_reports_already_migrated_noop
    with_tmp_global_config(runtime: false) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }

        out, _err = capture_io { migrate_command(dir).call }

        assert_includes out, "target stage directories look already-migrated"
      end
    end
  end

  def test_migrate_reports_plain_noop_when_legacy_dirs_only_have_non_slug_entries
    with_tmp_global_config(runtime: false) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        stages = File.join(dir, ".hive-state", "stages")
        ignored = File.join(stages, "5-review", ".DS_Store")
        FileUtils.mkdir_p(ignored)

        out, _err = capture_io { migrate_command(dir).call }

        assert_includes out, "hive: migrate found nothing to move"
        refute_includes out, "already-migrated"
        assert File.directory?(ignored), "non-slug entry must remain in the legacy stage directory"
      end
    end
  end

  # Commit-message assertion (round-1 finding): regression that drops
  # the commit (or changes the message) would otherwise be invisible.
  def test_migrate_writes_a_commit_with_descriptive_message
    with_tmp_global_config(runtime: false) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        stages = File.join(dir, ".hive-state", "stages")
        hive_state = File.dirname(stages)
        FileUtils.mkdir_p(File.join(stages, "5-review", "demo-260513-aaaa"))
        File.write(File.join(stages, "5-review", "demo-260513-aaaa", "task.md"), "x\n")

        capture_io { migrate_command(dir).call }

        log = `git -C #{hive_state.shellescape} log --oneline -5`
        assert $CHILD_STATUS.success?, "git log must succeed"
        assert_match(/hive: migrate stage directories \(1 task\)/, log,
                     "commit message must name the migrated task count")
      end
    end
  end

  # Config-key rewrite (round-1 finding + the transition-shim removal
  # path): `budget_usd.pr` / `timeout_sec.pr` get rewritten onto
  # `.finalize` so Stages::Finalize's read-through fallback has
  # somewhere to go.
  def test_migrate_rewrites_legacy_config_keys
    with_tmp_global_config(runtime: false) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        cfg_path = File.join(dir, ".hive-state", "config.yml")
        cfg = YAML.safe_load(File.read(cfg_path))
        # Set ONLY the legacy keys (delete the canonical to prove the
        # rewrite happens). When both keys exist post-rewrite, the
        # canonical wins by design (the user tuned post-migration).
        cfg["budget_usd"] ||= {}
        cfg["budget_usd"].delete("finalize")
        cfg["budget_usd"]["pr"] = 77
        cfg["timeout_sec"] ||= {}
        cfg["timeout_sec"].delete("finalize")
        cfg["timeout_sec"]["pr"] = 1234
        File.write(cfg_path, cfg.to_yaml)

        capture_io { migrate_command(dir).call }

        cfg_after = YAML.safe_load(File.read(cfg_path))
        refute cfg_after["budget_usd"].key?("pr"),
               "legacy `budget_usd.pr` key must be removed"
        assert_equal 77, cfg_after.dig("budget_usd", "finalize"),
                     "legacy value must propagate onto canonical `finalize` key"
        refute cfg_after["timeout_sec"].key?("pr")
        assert_equal 1234, cfg_after.dig("timeout_sec", "finalize")
      end
    end
  end

  # Idempotent rerun: when both legacy and canonical keys exist, the
  # canonical value wins (user-tuned post-migration).
  def test_migrate_preserves_canonical_on_collision_with_legacy
    with_tmp_global_config(runtime: false) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        cfg_path = File.join(dir, ".hive-state", "config.yml")
        cfg = YAML.safe_load(File.read(cfg_path))
        cfg["budget_usd"] ||= {}
        cfg["budget_usd"]["finalize"] = 99
        cfg["budget_usd"]["pr"] = 77
        File.write(cfg_path, cfg.to_yaml)

        capture_io { migrate_command(dir).call }

        cfg_after = YAML.safe_load(File.read(cfg_path))
        assert_equal 99, cfg_after.dig("budget_usd", "finalize"),
                     "canonical value must win on collision (user-tuned wins over legacy)"
        refute cfg_after["budget_usd"].key?("pr"),
               "legacy key must still be removed even when canonical wins"
      end
    end
  end

  def test_migrate_removes_retired_patrol_policy_once_and_restarts_daemon
    with_tmp_global_config(runtime: false) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        cfg_path = File.join(dir, ".hive-state", "config.yml")
        File.write(cfg_path, <<~YAML)
          # Keep this project comment.
          patrol:
            mode: off
            max_tokens_per_cycle: 100
            max_tokens_per_day: 200
            max_tokens_per_agent: 1000000000
            max_agent_spawns_per_cycle: 3
            max_agent_spawns_per_day: 4
            max_architecture_review_spawns_per_day: 5
            max_architecture_unmetered_spawns_per_day: 6
            max_budget_usd_per_agent: 7
            architecture_budget_multiplier: 8
            fix_budget_multiplier: 9
          refactor_patrol:
            enabled: false
            min_leverage_score: 0.10
            issue_filing:
              enabled: false
              min_leverage_score: 0.25
            leverage:
              weights:
                churn: 1.0
        YAML
        restarts = 0
        command = migrate_command(dir, daemon_restarter: -> { restarts += 1 })

        out, _err = capture_io { command.call }

        migrated_bytes = File.read(cfg_path)
        migrated = YAML.safe_load(migrated_bytes)
        assert_includes migrated_bytes, "# Keep this project comment."
        assert_equal 4, migrated.dig("patrol", "max_agent_spawns_per_day")
        Hive::Commands::Migrate::RETIRED_PATROL_CONFIG_KEYS.each do |key|
          refute migrated.fetch("patrol").key?(key), key
        end
        refute migrated.fetch("refactor_patrol").key?("min_leverage_score")
        refute migrated.fetch("refactor_patrol").key?("leverage")
        refute migrated.dig("refactor_patrol", "issue_filing").key?("min_leverage_score")
        assert_includes out, "rewrote legacy config keys"
        assert_equal 1, restarts

        second_out, _err = capture_io { command.call }
        assert_equal migrated_bytes, File.read(cfg_path)
        assert_equal 1, restarts, "idempotent migration must not request another restart"
        refute_includes second_out, "rewrote legacy config keys"
      end
    end
  end

  def test_migrate_keeps_comments_that_document_surviving_keys_after_retired_policy
    with_tmp_global_config(runtime: false) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        cfg_path = File.join(dir, ".hive-state", "config.yml")
        File.write(cfg_path, <<~YAML)
          patrol:
            max_tokens_per_day: 200
            # Token fuse retired; the daily launch ceiling follows.
            max_tokens_per_agent: 1000000000
            max_agent_spawns_per_day: 11
          refactor_patrol:
            enabled: false
            min_leverage_score: 0.10
            # Keep this with the surviving whole-run deadline.
            max_review_seconds_per_run: 3600
            issue_filing:
              enabled: false
              min_leverage_score: 0.25

          # Keep this with the following top-level section.
          review:
            auto_rebase: false
        YAML

        capture_io { migrate_command(dir, daemon_restarter: -> { }).call }

        migrated = File.read(cfg_path)
        assert_includes migrated, "# Token fuse retired; the daily launch ceiling follows."
        assert_includes migrated, "# Keep this with the surviving whole-run deadline."
        assert_includes migrated, "# Keep this with the following top-level section."
      end
    end
  end

  def test_failed_atomic_config_replacement_preserves_original_and_retry_succeeds
    with_tmp_global_config(runtime: false) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        cfg_path = File.join(dir, ".hive-state", "config.yml")
        File.write(cfg_path, "patrol:\n  mode: off\n  max_tokens_per_day: 2\n")
        FileUtils.chmod(0o600, cfg_path)
        original_bytes = File.binread(cfg_path)
        original_config = YAML.safe_load(original_bytes)
        original_rename = File.method(:rename)
        failing_rename = lambda do |source, target|
          raise Errno::EIO, "injected config replacement failure" if target == cfg_path

          original_rename.call(source, target)
        end
        command = migrate_command(dir, daemon_restarter: -> { })

        with_replaced_singleton_method(File, :rename, failing_rename) do
          assert_raises(Errno::EIO) { capture_io { command.call } }
        end

        assert_equal original_bytes, File.binread(cfg_path)
        assert_equal original_config, YAML.safe_load(File.binread(cfg_path))

        capture_io { command.call }

        migrated = YAML.safe_load(File.binread(cfg_path))
        refute migrated.fetch("patrol").key?("max_tokens_per_day")
        assert_equal 0o600, File.stat(cfg_path).mode & 0o777
      end
    end
  end

  def test_migrate_semantically_rewrites_flow_style_retired_patrol_policy
    with_tmp_global_config(runtime: false) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        cfg_path = File.join(dir, ".hive-state", "config.yml")
        before = "# Before Patrol.\nproject_name: preserve-before\n"
        between = "# Between target sections.\ntimeout_sec: {execute: 321}\n"
        after = "# After Refactor Patrol.\nreview:\n  require_ci: false\n"
        File.write(
          cfg_path,
          before +
          "patrol: {mode: off, max_tokens_per_day: 2, max_tokens_per_agent: 1000000000, " \
          "max_agent_spawns_per_day: 12}\n" +
          between +
          "refactor_patrol: {enabled: false, min_leverage_score: 0.1, " \
          "issue_filing: {enabled: false, min_leverage_score: 0.25}, " \
          "leverage: {weights: {churn: 1.0}}}\n" +
          after
        )
        command = migrate_command(dir, daemon_restarter: -> { })

        capture_io { command.call }

        migrated_bytes = File.read(cfg_path)
        migrated = YAML.safe_load(migrated_bytes)
        assert migrated_bytes.start_with?(before)
        assert_includes migrated_bytes, between
        assert migrated_bytes.end_with?(after)
        assert_equal 12, migrated.dig("patrol", "max_agent_spawns_per_day")
        refute migrated.fetch("patrol").key?("max_tokens_per_agent")
        refute migrated.fetch("patrol").key?("max_tokens_per_day")
        refute migrated.fetch("refactor_patrol").key?("min_leverage_score")
        refute migrated.fetch("refactor_patrol").key?("leverage")
        refute migrated.dig("refactor_patrol", "issue_filing").key?("min_leverage_score")

        capture_io { command.call }
        assert_equal migrated_bytes, File.read(cfg_path)
      end
    end
  end

  def test_retired_policy_rewrite_fails_closed_when_section_normalization_is_incomplete
    command = migrate_command("/tmp/project")
    content = "patrol: {mode: off, max_tokens_per_day: 2}\n"

    with_replaced_singleton_method(
      command, :normalize_retired_patrol_section, ->(*) { content }
    ) do
      error = assert_raises(Hive::ConfigError) do
        command.send(
          :rewrite_retired_patrol_policy,
          content,
          "/tmp/project/.hive-state/config.yml"
        )
      end

      assert_match(/without rewriting unrelated config/, error.message)
    end
  end

  def test_section_normalization_rejects_a_non_mapping_document
    error = assert_raises(Hive::ConfigError) do
      migrate_command("/tmp/project").send(
        :normalize_retired_patrol_section,
        "- patrol\n",
        "patrol",
        {},
        "/tmp/project/.hive-state/config.yml"
      )
    end

    assert_match(/must be a hash/, error.message)
  end

  def test_section_normalization_rejects_a_non_scalar_top_level_alias
    content = "section: &name patrol\n*name: {mode: off}\n"

    error = assert_raises(Hive::ConfigError) do
      migrate_command("/tmp/project").send(
        :normalize_retired_patrol_section,
        content,
        "patrol",
        { "mode" => false },
        "/tmp/project/.hive-state/config.yml"
      )
    end

    assert_match(/cannot locate top-level `patrol`/, error.message)
  end

  def test_section_normalization_preserves_the_blank_separator_after_a_block
    content = <<~YAML
      patrol:
        mode: off
        max_tokens_per_day: 2

      review:
        require_ci: false
    YAML

    rewritten = migrate_command("/tmp/project").send(
      :normalize_retired_patrol_section,
      content,
      "patrol",
      { "mode" => false },
      "/tmp/project/.hive-state/config.yml"
    )

    assert_equal <<~YAML, rewritten
      patrol:
        mode: false

      review:
        require_ci: false
    YAML
  end

  def test_migrate_rejects_a_non_mapping_config_before_rewriting_retired_policy
    with_tmp_global_config(runtime: false) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        cfg_path = File.join(dir, ".hive-state", "config.yml")
        File.write(cfg_path, "- patrol\n- refactor_patrol\n")

        error = assert_raises(Hive::ConfigError) do
          migrate_command(dir, daemon_restarter: -> { }).call
        end

        assert_match(/must be a hash/, error.message)
      end
    end
  end

  def test_migrate_removes_complete_multiline_retired_patrol_values
    with_tmp_global_config(runtime: false) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        cfg_path = File.join(dir, ".hive-state", "config.yml")
        File.write(cfg_path, <<~YAML)
          patrol:
            mode: off
            max_tokens_per_day: |
              100
              # An old operator note must be retired with the value.
              200
            max_agent_spawns_per_cycle:
              - 3
              - 4
            max_budget_usd_per_agent: >
              7
              dollars
            max_tokens_per_agent: 1000000000
            max_agent_spawns_per_day: 4
          refactor_patrol:
            enabled: false
        YAML

        capture_io { migrate_command(dir, daemon_restarter: -> { }).call }

        migrated_bytes = File.read(cfg_path)
        migrated = YAML.safe_load(migrated_bytes)
        assert_equal false, migrated.dig("patrol", "mode")
        assert_equal 4, migrated.dig("patrol", "max_agent_spawns_per_day")
        Hive::Commands::Migrate::RETIRED_PATROL_CONFIG_KEYS.each do |key|
          refute migrated.fetch("patrol").key?(key), key
        end
        refute_includes migrated_bytes, "100\n200"
        refute_includes migrated_bytes, "dollars"
      end
    end
  end

  def test_config_rewrite_requests_coalesced_restart_before_later_migration_failure
    with_tmp_global_config(runtime: false) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        cfg_path = File.join(dir, ".hive-state", "config.yml")
        File.write(cfg_path, "patrol:\n  max_tokens_per_day: 2\n")
        restarts = 0
        command = migrate_command(
          dir,
          config_loader: ->(*) { raise Hive::ConfigError, "later migration failed" },
          daemon_restarter: -> { restarts += 1 }
        )

        assert_raises(Hive::ConfigError) { capture_io { command.call } }

        assert_equal 1, restarts
        refute YAML.safe_load(File.read(cfg_path)).fetch("patrol").key?("max_tokens_per_day")
      end
    end
  end

  def test_standalone_config_rewrite_restarts_daemon_before_later_migration_failure
    with_tmp_global_config(runtime: false) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        cfg_path = File.join(dir, ".hive-state", "config.yml")
        File.write(cfg_path, "patrol:\n  max_tokens_per_day: 2\n")
        restarts = 0
        command = migrate_command(
          dir,
          config_loader: ->(*) { raise Hive::ConfigError, "later migration failed" }
        )
        command.define_singleton_method(:restart_daemon_if_running!) { restarts += 1 }

        assert_raises(Hive::ConfigError) { capture_io { command.call } }

        assert_equal 1, restarts
        refute YAML.safe_load(File.read(cfg_path)).fetch("patrol").key?("max_tokens_per_day")
      end
    end
  end

  def test_migrate_moves_top_level_reviewers_under_review_without_losing_comments
    with_tmp_global_config(runtime: false) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        cfg_path = File.join(dir, ".hive-state", "config.yml")
        File.write(cfg_path, <<~YAML)
          review:
            # Keep the existing review settings.
            require_ci: false
          # Reviewers: Codex routing.
          # Keep this leading explanation with the reviewer block.
          reviewers:
            # Keep the legacy reviewer explanation.
            - name: legacy
              kind: agent
              agent: codex
              skill: ce-code-review
              output_basename: legacy
              prompt_template: reviewer_codex_ce_code_review.md.erb
        YAML

        out, _err = capture_io { migrate_command(dir).call }

        migrated = File.read(cfg_path)
        cfg_after = YAML.safe_load(migrated)
        refute cfg_after.key?("reviewers")
        assert_equal [ "legacy" ], cfg_after.dig("review", "reviewers").map { |entry| entry.fetch("name") }
        assert_includes migrated, "  # Reviewers: Codex routing."
        assert_includes migrated, "  # Keep this leading explanation with the reviewer block."
        refute_match(/^# Reviewers: Codex routing\.$/, migrated)
        assert_includes migrated, "  # Keep the legacy reviewer explanation."
        assert_includes migrated, "  # Keep the existing review settings."
        assert_includes out, "rewrote legacy config keys"
        assert_equal [ "legacy" ], Hive::Config.load(dir).dig("review", "reviewers").map { |entry| entry.fetch("name") }
      end
    end
  end

  def test_migrate_creates_review_mapping_when_legacy_reviewers_are_the_only_key
    with_tmp_global_config(runtime: false) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        cfg_path = File.join(dir, ".hive-state", "config.yml")
        File.write(cfg_path, "reviewers: []\n")

        capture_io { migrate_command(dir).call }

        assert_equal({ "review" => { "reviewers" => [] } }, YAML.safe_load(File.read(cfg_path)))
      end
    end
  end

  def test_migrate_rejects_flow_style_review_mapping_without_reformatting_the_file
    with_tmp_global_config(runtime: false) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        cfg_path = File.join(dir, ".hive-state", "config.yml")
        File.write(cfg_path, "review: { require_ci: false }\nreviewers: []\n")
        before = File.read(cfg_path)

        error = assert_raises(Hive::ConfigError) do
          capture_io { migrate_command(dir).call }
        end

        assert_includes error.message, "`review` is not written as a block mapping"
        assert_equal before, File.read(cfg_path)
      end
    end
  end

  def test_migrate_reports_invalid_yaml_before_rewriting_legacy_reviewers
    with_tmp_global_config(runtime: false) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        cfg_path = File.join(dir, ".hive-state", "config.yml")
        File.write(cfg_path, "reviewers: [\n")

        error = assert_raises(Hive::ConfigError) do
          capture_io { migrate_command(dir).call }
        end

        assert_includes error.message, "config.yml at #{cfg_path} is not valid YAML"
      end
    end
  end

  def test_migrate_refuses_to_choose_between_legacy_and_canonical_reviewers
    with_tmp_global_config(runtime: false) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        cfg_path = File.join(dir, ".hive-state", "config.yml")
        File.write(cfg_path, <<~YAML)
          review:
            reviewers: []
          reviewers:
            - name: legacy
        YAML
        before = File.read(cfg_path)

        error = assert_raises(Hive::ConfigError) do
          capture_io { migrate_command(dir).call }
        end

        assert_includes error.message, "both top-level `reviewers` and `review.reviewers`"
        assert_equal before, File.read(cfg_path)
      end
    end
  end

  # When legacy config keys are rewritten AND task ids are backfilled in the
  # same run (with no stage folders to move), the no-move message reports both.
  def test_migrate_no_move_message_reports_config_rewrite_and_backfill
    with_tmp_global_config(runtime: false) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        cfg_path = File.join(dir, ".hive-state", "config.yml")
        cfg = YAML.safe_load(File.read(cfg_path))
        cfg["budget_usd"] ||= {}
        cfg["budget_usd"].delete("finalize")
        cfg["budget_usd"]["pr"] = 77
        File.write(cfg_path, cfg.to_yaml)
        stages = File.join(dir, ".hive-state", "stages")
        write_task_folder(stages, "2-brainstorm", "needs-id-260603-aaaa")

        out, _err = capture_io { migrate_command(dir).call }

        assert_includes out, "rewrote legacy config keys and backfilled 1 task id",
                         "combined config-rewrite + backfill no-move message must report both"
      end
    end
  end

  def test_migrate_backfills_task_meta_ids_in_created_at_order
    with_tmp_global_config(runtime: false) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        stages = File.join(dir, ".hive-state", "stages")
        later = write_task_folder(stages, "2-brainstorm", "later-task-260603-bbbb", created_at: "2026-06-03T12:00:00Z")
        earlier = write_task_folder(stages, "2-brainstorm", "early-task-260603-aaaa", created_at: "2026-06-03T11:00:00Z")
        no_idea = write_task_folder(stages, "2-brainstorm", "no-idea-260603-cccc", idea: false)

        out, _err = capture_io { migrate_command(dir).call }

        assert_includes out, "backfilled 3 task ids"
        assert_equal({ id: 1, slug: "early-task-260603-aaaa", display_name: nil, depends_on: nil, workflow: nil,
                       plan_review_required: true },
                     Hive::TaskMeta.read(earlier))
        assert_equal({ id: 2, slug: "later-task-260603-bbbb", display_name: nil, depends_on: nil, workflow: nil,
                       plan_review_required: true },
                     Hive::TaskMeta.read(later))
        assert_equal({ id: 3, slug: "no-idea-260603-cccc", display_name: nil, depends_on: nil, workflow: nil,
                       plan_review_required: true },
                     Hive::TaskMeta.read(no_idea))
        assert_equal 4, Hive::TaskCounter.peek
      end
    end
  end

  def test_migrate_upgrades_idless_recovery_markers_once
    with_tmp_global_config(runtime: false) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        stages = File.join(dir, ".hive-state", "stages")
        error_folder = write_task_folder(
          stages, "4-execute", "old-error-260725-aaaa"
        )
        review_folder = write_task_folder(
          stages, "6-review", "old-review-error-260725-bbbb"
        )
        Hive::TaskMeta.write(
          error_folder, id: 101, slug: File.basename(error_folder),
          display_name: "Old error"
        )
        Hive::TaskMeta.write(
          review_folder, id: 102, slug: File.basename(review_folder),
          display_name: "Old review error"
        )
        File.write(
          File.join(error_folder, "task.md"),
          "# Task\n\n<!-- ERROR reason=timeout -->\n"
        )
        File.write(
          File.join(review_folder, "task.md"),
          "# Task\n\n<!-- REVIEW_ERROR reason=all_failed -->\n"
        )
        historical_plan = File.join(error_folder, "plan.md")
        File.write(
          historical_plan,
          "# Historical plan failure\n\n<!-- ERROR reason=old_plan_failure -->\n"
        )

        out, _err = capture_io { migrate_command(dir).call }
        error_marker = Hive::Markers.current(File.join(error_folder, "task.md"))
        review_marker = Hive::Markers.current(File.join(review_folder, "task.md"))

        assert_includes out, "upgraded 2 recovery markers"
        refute_empty error_marker.attrs.fetch("marker_id")
        refute_empty review_marker.attrs.fetch("marker_id")
        assert_equal "timeout", error_marker.attrs.fetch("reason")
        assert_equal "all_failed", review_marker.attrs.fetch("reason")
        assert_empty Hive::Markers.current(historical_plan).attrs.fetch("marker_id", ""),
                     "migration must not rewrite a marker-shaped comment in a non-current artifact"

        ids = [
          error_marker.attrs.fetch("marker_id"),
          review_marker.attrs.fetch("marker_id")
        ]
        second_out, _err = capture_io { migrate_command(dir).call }

        assert_includes second_out, "target stage directories look already-migrated"
        assert_equal ids.fetch(0),
                     Hive::Markers.current(File.join(error_folder, "task.md")).attrs.fetch("marker_id")
        assert_equal ids.fetch(1),
                     Hive::Markers.current(File.join(review_folder, "task.md")).attrs.fetch("marker_id")
      end
    end
  end

  def test_migrate_upgrades_the_authoritative_state_file_for_a_custom_workflow
    with_registered_workflow(research_workflow) do
      with_tmp_global_config(runtime: false) do
        with_tmp_git_repo do |dir|
          capture_io { Hive::Commands::Init.new(dir).call }
          stages = File.join(dir, ".hive-state", "stages")
          folder = write_task_folder(
            stages, "2-gather", "custom-recovery-260725-aaaa"
          )
          Hive::TaskMeta.write(
            folder, id: 103, slug: File.basename(folder),
            display_name: "Custom recovery", workflow: "research"
          )
          File.write(
            File.join(folder, "notes.md"),
            "# Notes\n\n<!-- ERROR reason=timeout -->\n"
          )
          File.write(
            File.join(folder, "task.md"),
            "# Historical coding-shaped file\n\n<!-- ERROR reason=historical -->\n"
          )

          out, _err = capture_io { migrate_command(dir).call }

          assert_includes out, "upgraded 1 recovery marker"
          refute_empty Hive::Markers.current(
            File.join(folder, "notes.md")
          ).attrs.fetch("marker_id")
          assert_empty Hive::Markers.current(
            File.join(folder, "task.md")
          ).attrs.fetch("marker_id", "")
        end
      end
    end
  end

  def test_migrate_backfill_is_idempotent
    with_tmp_global_config(runtime: false) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        stages = File.join(dir, ".hive-state", "stages")
        folder = write_task_folder(stages, "3-plan", "existing-task-260603-aaaa")

        capture_io { migrate_command(dir).call }
        first = Hive::TaskMeta.read(folder)
        first_counter = Hive::TaskCounter.peek
        out, _err = capture_io { migrate_command(dir).call }

        assert_includes out, "target stage directories look already-migrated"
        assert_equal first, Hive::TaskMeta.read(folder)
        assert_equal first_counter, Hive::TaskCounter.peek
      end
    end
  end

  def test_migrate_fills_null_id_and_preserves_display_name
    with_tmp_global_config(runtime: false) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        stages = File.join(dir, ".hive-state", "stages")
        folder = write_task_folder(stages, "4-execute", "named-task-260603-aaaa")
        Hive::TaskMeta.write(folder, id: nil, slug: "named-task-260603-aaaa", display_name: "Named Task")

        capture_io { migrate_command(dir).call }

        assert_equal({ id: 1, slug: "named-task-260603-aaaa", display_name: "Named Task",
                       depends_on: nil, workflow: nil },
                     Hive::TaskMeta.read(folder))
      end
    end
  end

  # The id-backfill path re-writes meta.yml; dropping the depends_on arg
  # there would silently strip a task's dependency during migrate. Seed a
  # populated depends_on and assert it survives a full migrate run.
  def test_migrate_fills_null_id_and_preserves_depends_on
    with_tmp_global_config(runtime: false) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        stages = File.join(dir, ".hive-state", "stages")
        folder = write_task_folder(stages, "4-execute", "dependent-task-260603-aaaa")
        Hive::TaskMeta.write(
          folder,
          id: nil,
          slug: "dependent-task-260603-aaaa",
          display_name: "Dependent Task",
          depends_on: "base-task-260603-bbbb"
        )

        capture_io { migrate_command(dir).call }

        assert_equal(
          { id: 1, slug: "dependent-task-260603-aaaa",
            display_name: "Dependent Task", depends_on: "base-task-260603-bbbb", workflow: nil },
          Hive::TaskMeta.read(folder),
          "migrate's id-backfill must preserve depends_on, not strip it"
        )
      end
    end
  end

  # The id-backfill path must preserve the complete managed workflow pin.
  # Dropping any field can silently change the workflow or make its immutable
  # generation/configuration impossible to resolve.
  def test_migrate_fills_null_id_and_preserves_managed_workflow_provenance
    with_tmp_global_config(runtime: false) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        stages = File.join(dir, ".hive-state", "stages")
        folder = write_task_folder(stages, "4-execute", "generic-task-260603-aaaa")
        Hive::TaskMeta.write(
          folder,
          id: nil,
          slug: "generic-task-260603-aaaa",
          display_name: "Generic Task",
          workflow: "research",
          base_branch: "launch",
          workflow_commit: "c" * 40,
          workflow_manifest_digest: "d" * 64,
          workflow_configuration_digest: "e" * 64
        )

        store = Object.new
        store.define_singleton_method(:selected) do |_name, cfg:|
          {
            "source_commit" => "c" * 40,
            "manifest_digest" => "d" * 64,
            "configuration_digest" => "e" * 64
          }
        end
        research_workflow = migration_workflow("inbox", "brainstorm", "plan", "execute")
        store.define_singleton_method(:workflow) { |*_args, **_kwargs| research_workflow }
        capture_io do
          migrate_command(
            dir,
            managed_store_factory: ->(_path) { store },
            config_loader: ->(_path) { { "project_name" => "demo" } }
          ).call
        end

        assert_equal(
          { id: 1, slug: "generic-task-260603-aaaa",
            display_name: "Generic Task", depends_on: nil, workflow: "research",
            base_branch: "launch", workflow_commit: "c" * 40,
            workflow_manifest_digest: "d" * 64,
            workflow_configuration_digest: "e" * 64 },
          Hive::TaskMeta.read(folder),
          "migrate's id-backfill must preserve complete workflow provenance"
        )
      end
    end
  end

  def test_migrate_backfills_missing_display_names_without_renaming_existing_names
    with_tmp_global_config(runtime: false) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        stages = File.join(dir, ".hive-state", "stages")
        hive_state = File.dirname(stages)
        missing_name = write_task_folder(stages, "4-execute", "missing-readable-name-260603-aaaa")
        existing_name = write_task_folder(stages, "4-execute", "already-named-task-260603-bbbb")
        Hive::TaskMeta.write(existing_name, id: 7, slug: "already-named-task-260603-bbbb", display_name: "Already Named")
        RecordingDisplayNameGenerator.calls = []

        out, _err = capture_io do
          migrate_command(dir, display_name_generator: RecordingDisplayNameGenerator).call
        end

        assert_includes out, "backfilled 1 display name"
        assert_equal "Missing Readable Name", Hive::TaskMeta.read(missing_name)[:display_name]
        assert_equal "Already Named", Hive::TaskMeta.read(existing_name)[:display_name]
        assert_equal [ { slug: "missing-readable-name-260603-aaaa", commit: false, project: File.basename(dir) } ],
                     RecordingDisplayNameGenerator.calls

        log = `git -C #{hive_state.shellescape} log --oneline -5`
        assert $CHILD_STATUS.success?, "git log must succeed"
        assert_match(/hive: migrate display names \(1 task\)/, log)
      end
    end
  end

  def test_migrate_backfills_archived_completion_times_explicitly
    with_tmp_global_config(runtime: false) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        stages = File.join(dir, ".hive-state", "stages")
        hive_state = File.dirname(stages)
        folder = write_task_folder(stages, "9-done", "legacy-archive-260603-aaaa")
        state_file = File.join(folder, "task.md")
        File.write(state_file, "<!-- COMPLETE -->\n")
        Hive::TaskMeta.write(
          folder, id: 7, slug: File.basename(folder), display_name: "Legacy archive"
        )
        completed_at = Time.utc(2026, 6, 1, 12, 0, 0)
        File.utime(completed_at, completed_at, state_file)
        assert system("git", "-C", hive_state, "add", "-A", out: File::NULL, err: File::NULL)
        assert system(
          "git", "-C", hive_state, "commit", "-m", "test: add legacy archive",
          out: File::NULL, err: File::NULL
        )
        operator_note = File.join(hive_state, "operator-note.txt")
        File.write(operator_note, "keep me outside migration commits\n")

        out, _err = capture_io { migrate_command(dir).call }

        assert_equal completed_at.iso8601, Hive::TaskMeta.read(folder)[:completed_at]
        assert_includes out, "backfilled 1 completion time"
        log = `git -C #{hive_state.shellescape} log --oneline -5`
        assert $CHILD_STATUS.success?, "git log must succeed"
        assert_match(/hive: migrate completion times \(1 task\)/, log)
        status = `git -C #{hive_state.shellescape} status --short -- operator-note.txt`.strip
        assert_equal "?? operator-note.txt", status

        migrated_head = `git -C #{hive_state.shellescape} rev-parse HEAD`.strip
        second_out, _second_err = capture_io { migrate_command(dir).call }
        assert_equal migrated_head, `git -C #{hive_state.shellescape} rev-parse HEAD`.strip
        refute_includes second_out, "backfilled 1 completion time"
      end
    end
  end

  def test_completion_time_commit_failure_restores_metadata_for_a_retry
    with_tmp_global_config(runtime: false) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        stages = File.join(dir, ".hive-state", "stages")
        hive_state = File.dirname(stages)
        folder = write_task_folder(stages, "9-done", "legacy-archive-260603-bbbb")
        state_file = File.join(folder, "task.md")
        File.write(state_file, "<!-- COMPLETE -->\n")
        Hive::TaskMeta.write(
          folder, id: 8, slug: File.basename(folder), display_name: "Legacy archive"
        )
        completed_at = Time.utc(2026, 6, 1, 12, 0, 0)
        File.utime(completed_at, completed_at, state_file)
        assert system("git", "-C", hive_state, "add", "-A", out: File::NULL, err: File::NULL)
        assert system(
          "git", "-C", hive_state, "commit", "-m", "test: add legacy archive",
          out: File::NULL, err: File::NULL
        )
        migrate = migrate_command(dir)
        migrate.define_singleton_method(:commit_metadata_backfill!) do |*, **|
          raise Hive::GitError, "simulated commit failure"
        end

        assert_raises(Hive::GitError) { capture_io { migrate.call } }

        assert_nil Hive::TaskMeta.read(folder)[:completed_at]
        assert system("git", "-C", hive_state, "diff", "--quiet")
        assert system("git", "-C", hive_state, "diff", "--cached", "--quiet")

        capture_io { migrate_command(dir).call }
        assert_equal completed_at.iso8601, Hive::TaskMeta.read(folder)[:completed_at]
      end
    end
  end

  def test_invalid_completion_time_keeps_that_task_visible_and_commits_earlier_metadata
    with_tmp_global_config(runtime: false) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        stages = File.join(dir, ".hive-state", "stages")
        hive_state = File.dirname(stages)
        completed_times = []
        folders = %w[
          legacy-archive-260603-cccc
          legacy-archive-260603-dddd
        ].map.with_index do |slug, index|
          folder = write_task_folder(stages, "9-done", slug)
          state_file = File.join(folder, "task.md")
          File.write(state_file, "<!-- COMPLETE -->\n")
          Hive::TaskMeta.write(
            folder, id: 9 + index, slug: slug, display_name: "Legacy archive #{index + 1}"
          )
          completed_at = Time.utc(2026, 6, 1, 12, 0, index)
          File.utime(completed_at, completed_at, state_file)
          completed_times << completed_at
          folder
        end
        File.open(Hive::TaskMeta.path(folders.last), "a") do |file|
          file.write("completed_at: \"2026-06-01\"\n")
        end
        assert system("git", "-C", hive_state, "add", "-A", out: File::NULL, err: File::NULL)
        assert system(
          "git", "-C", hive_state, "commit", "-m", "test: add legacy archives",
          out: File::NULL, err: File::NULL
        )
        out, err = capture_io { migrate_command(dir).call }

        assert_equal completed_times.first.iso8601, Hive::TaskMeta.read(folders.first)[:completed_at]
        invalid_clock = nil
        capture_io { invalid_clock = Hive::TaskMeta.read(folders.last)[:completed_at] }
        assert_nil invalid_clock
        assert_includes out, "backfilled 1 completion time"
        assert_includes err, "could not migrate a completion time"
        assert system("git", "-C", hive_state, "diff", "--quiet")
        assert system("git", "-C", hive_state, "diff", "--cached", "--quiet")
      end
    end
  end

  def test_completion_time_discovery_warns_when_no_credible_source_exists
    command = migrate_command("/tmp/project")
    task = Struct.new(:completed_at, :state_file, :slug).new(nil, "/tmp/task.md", "legacy")
    command.define_singleton_method(:archived_task?) { |*, **| true }

    with_replaced_singleton_method(Hive::Task, :new, ->(*, **) { task }) do
      with_replaced_singleton_method(Hive::Markers, :current, ->(*) { nil }) do
        with_replaced_singleton_method(Hive::CompletionTime, :discover, ->(*) { nil }) do
          value = nil
          _out, err = capture_io do
            value = command.send(
              :discover_completion_time, "/tmp/task",
              workflow_generation: nil, config: {}, history: Object.new
            )
          end

          assert_nil value
          assert_includes err, "could not discover a completion time for legacy"
        end
      end
    end
  end

  def test_completion_time_discovery_does_not_swallow_interrupts
    command = migrate_command("/tmp/project")
    task = Struct.new(:completed_at, :state_file, :slug).new(nil, "/tmp/task.md", "legacy")
    command.define_singleton_method(:archived_task?) { |*, **| true }

    with_replaced_singleton_method(Hive::Task, :new, ->(*, **) { task }) do
      with_replaced_singleton_method(Hive::Markers, :current, ->(*) { nil }) do
        with_replaced_singleton_method(
          Hive::CompletionTime, :discover, ->(*) { raise Interrupt }
        ) do
          assert_raises(Interrupt) do
            command.send(
              :discover_completion_time, "/tmp/task",
              workflow_generation: nil, config: {}, history: Object.new
            )
          end
        end
      end
    end
  end

  def test_completion_time_transaction_restores_snapshots_after_an_interrupt
    command = migrate_command("/tmp/project")
    restored = nil
    command.define_singleton_method(:persist_completion_time) do |folder, *, snapshots:, **|
      snapshots[folder] = :before
      true
    end
    command.define_singleton_method(:commit_metadata_backfill!) { |*, **| raise Interrupt }
    command.define_singleton_method(:restore_completion_time_backfill) do |state, snapshots|
      restored = [ state, snapshots.dup ]
    end

    assert_raises(Interrupt) do
      command.send(
        :persist_completion_times_and_commit,
        "/state", { "/task" => Time.utc(2026, 7, 1) },
        workflow_generation: nil, config: {}
      )
    end

    assert_equal [ "/state", { "/task" => :before } ], restored
  end

  def test_completion_time_persistence_does_not_swallow_interrupts
    with_tmp_dir do |folder|
      command = migrate_command("/tmp/project")
      task = Struct.new(:completed_at, :state_file).new(nil, File.join(folder, "task.md"))
      command.define_singleton_method(:archived_task?) { |*, **| true }

      with_replaced_singleton_method(Hive::Task, :new, ->(*, **) { task }) do
        with_replaced_singleton_method(Hive::Markers, :current, ->(*) { nil }) do
          with_replaced_singleton_method(Hive::TaskMeta, :snapshot, ->(*) { :before }) do
            with_replaced_singleton_method(
              Hive::TaskMeta, :write_completed_at_once, ->(*) { raise Interrupt }
            ) do
              assert_raises(Interrupt) do
                command.send(
                  :persist_completion_time, folder, Time.utc(2026, 7, 1),
                  workflow_generation: nil, config: {}, snapshots: {}
                )
              end
            end
          end
        end
      end
    end
  end

  def test_completion_time_restore_reports_and_reraises_restore_failures
    command = migrate_command("/tmp/project")

    with_replaced_singleton_method(
      Hive::TaskMeta, :restore, ->(*) { raise IOError, "restore failed" }
    ) do
      _out, err = capture_io do
        assert_raises(IOError) do
          command.send(
            :restore_completion_time_backfill, "/state", { "/task" => :before }
          )
        end
      end

      assert_includes err, "could not restore completion-time metadata"
      assert_includes err, "restore failed"
    end
  end

  def test_migrate_seeds_counter_above_existing_ids
    with_tmp_global_config(runtime: false) do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        stages = File.join(dir, ".hive-state", "stages")
        existing = write_task_folder(stages, "3-plan", "existing-id-260603-aaaa")
        new_task = write_task_folder(stages, "3-plan", "new-id-260603-bbbb")
        Hive::TaskMeta.write(existing, id: 41, slug: "existing-id-260603-aaaa", display_name: nil)

        capture_io { migrate_command(dir).call }

        assert_equal 41, Hive::TaskMeta.read(existing)[:id]
        assert_equal 42, Hive::TaskMeta.read(new_task)[:id]
        assert_equal 43, Hive::TaskCounter.peek
      end
    end
  end

  def test_migrate_warns_with_recovery_command_when_git_commit_fails
    fake_ops = Object.new
    fake_ops.define_singleton_method(:run_git!) do |*_args|
      raise Hive::GitError, "permission denied"
    end
    migrate = migrate_command("/tmp/project")

    with_replaced_singleton_method(Hive::GitOps, :new, lambda { |_project_path| fake_ops }) do
      _out, err = capture_io do
        migrate.send(:commit_migration, "/tmp/project/.hive-state", [ [ "5-review", "6-review", "demo-260525-aaaa" ] ])
      end

      assert_includes err, "could not commit them to the hive-state git history"
      assert_includes err, "git -C /tmp/project/.hive-state add -A"
      assert_includes err, "hive: migrate stage directories (1 task)"
    end
  end

  def test_migrate_warns_with_recovery_command_when_display_name_commit_fails
    fake_ops = Object.new
    fake_ops.define_singleton_method(:run_git!) do |*_args|
      raise Hive::GitError, "permission denied"
    end
    migrate = migrate_command("/tmp/project")

    with_replaced_singleton_method(Hive::GitOps, :new, lambda { |_project_path| fake_ops }) do
      _out, err = capture_io do
        migrate.send(
          :commit_metadata_backfill, "/tmp/project/.hive-state",
          label: "display names", count: 2
        )
      end

      assert_includes err, "could not commit them to the hive-state git history"
      assert_includes err, "git -C /tmp/project/.hive-state add -A"
      assert_includes err, "hive: migrate display names (2 tasks)"
    end
  end

  def test_migrate_warns_with_singular_display_name_recovery_command
    fake_ops = Object.new
    fake_ops.define_singleton_method(:run_git!) do |*_args|
      raise Hive::GitError, "permission denied"
    end
    migrate = migrate_command("/tmp/project")

    with_replaced_singleton_method(Hive::GitOps, :new, lambda { |_project_path| fake_ops }) do
      _out, err = capture_io do
        migrate.send(
          :commit_metadata_backfill, "/tmp/project/.hive-state",
          label: "display names", count: 1
        )
      end

      assert_includes err, "hive: migrate display names (1 task)'"
      refute_includes err, "1 tasks"
    end
  end

  def test_restart_daemon_uses_the_shared_service_owner_when_available
    migrate = migrate_command("/tmp/project")
    calls = []
    installer = fake_daemon_service_installer(available: true) { calls << :restart }
    migrate.define_singleton_method(:read_daemon_pid) { 1234 }
    migrate.define_singleton_method(:daemon_alive?) { |_pid| true }
    migrate.define_singleton_method(:daemon_service_installer) { installer }

    out, err = capture_io { migrate.send(:restart_daemon_if_running!) }

    assert_equal [ :restart ], calls
    assert_includes out, "restarted hive-daemon (pid 1234)"
    assert_empty err
  end

  def test_default_daemon_service_installer_uses_the_shared_adapter
    installer = migrate_command("/tmp/project").send(:daemon_service_installer)

    assert_instance_of Hive::Commands::Daemon::ServiceInstaller, installer
  end

  def test_restart_daemon_warns_when_the_owned_restart_fails
    migrate = migrate_command("/tmp/project")
    installer = fake_daemon_service_installer(available: true) { raise Hive::Error, "busy" }
    migrate.define_singleton_method(:read_daemon_pid) { 1234 }
    migrate.define_singleton_method(:daemon_alive?) { |_pid| true }
    migrate.define_singleton_method(:daemon_service_installer) { installer }

    _out, err = capture_io { migrate.send(:restart_daemon_if_running!) }

    assert_includes err, "owned restart failed"
  end

  def test_restart_daemon_warns_when_the_service_manager_is_unavailable
    migrate = migrate_command("/tmp/project")
    installer = fake_daemon_service_installer(available: false)
    migrate.define_singleton_method(:read_daemon_pid) { 1234 }
    migrate.define_singleton_method(:daemon_alive?) { |_pid| true }
    migrate.define_singleton_method(:daemon_service_installer) { installer }

    _out, err = capture_io { migrate.send(:restart_daemon_if_running!) }

    assert_includes err, "restart it manually so its in-memory stage layout refreshes"
  end

  def test_patrol_index_cutover_restart_fails_closed_without_a_service_manager
    migrate = migrate_command("/tmp/project")
    installer = fake_daemon_service_installer(available: false)
    migrate.define_singleton_method(:read_daemon_pid) { 1234 }
    migrate.define_singleton_method(:daemon_alive?) { |_pid| true }
    migrate.define_singleton_method(:daemon_service_installer) { installer }

    error = assert_raises(Hive::Error) do
      migrate.send(:restart_daemon_for_patrol_index_cutover!)
    end

    assert_includes error.message, "hive daemon stop"
    assert_includes error.message, "rerun `hive migrate`"
  end

  def test_patrol_index_cutover_restart_is_synchronous
    migrate = migrate_command("/tmp/project")
    calls = []
    installer = fake_daemon_service_installer(available: true) { calls << :restart }
    migrate.define_singleton_method(:read_daemon_pid) { 1234 }
    migrate.define_singleton_method(:daemon_alive?) { |_pid| true }
    migrate.define_singleton_method(:daemon_service_installer) { installer }

    restarted = nil
    out, err = capture_io do
      restarted = migrate.send(:restart_daemon_for_patrol_index_cutover!)
    end

    assert restarted
    assert_equal [ :restart ], calls
    assert_includes out, "Patrol Fix admission index cutover"
    assert_empty err
  end

  def test_patrol_index_cutover_class_entrypoint_delegates_to_the_instance
    fake = Object.new
    fake.define_singleton_method(:restart_daemon_for_patrol_index_cutover!) { :restarted }
    original_new = Hive::Commands::Migrate.method(:new)
    Hive::Commands::Migrate.define_singleton_method(:new) { fake }

    assert_equal :restarted,
                 Hive::Commands::Migrate.restart_daemon_for_patrol_index_cutover!
  ensure
    Hive::Commands::Migrate.define_singleton_method(:new, original_new)
  end

  def test_patrol_index_cutover_restart_failure_is_actionable
    migrate = migrate_command("/tmp/project")
    installer = fake_daemon_service_installer(available: true) { raise Hive::Error, "busy" }
    migrate.define_singleton_method(:read_daemon_pid) { 1234 }
    migrate.define_singleton_method(:daemon_alive?) { |_pid| true }
    migrate.define_singleton_method(:daemon_service_installer) { installer }

    error = assert_raises(Hive::Error) do
      migrate.send(:restart_daemon_for_patrol_index_cutover!)
    end

    assert_includes error.message, "could not restart hive-daemon"
    assert_includes error.message, "rerun `hive migrate`"
  end

  def test_read_daemon_pid_accepts_hash_payload
    with_tmp_dir do |dir|
      File.write(File.join(dir, ".daemon.pid"), { "pid" => 4321 }.to_yaml)
      with_env("HIVE_HOME" => dir) do
        assert_equal 4321, migrate_command("/tmp/project").send(:read_daemon_pid)
      end
    end
  end

  def test_read_daemon_pid_returns_nil_when_pid_file_cannot_be_read
    with_tmp_dir do |dir|
      pid_file = File.join(dir, ".daemon.pid")
      File.write(pid_file, { "pid" => 4321 }.to_yaml)
      original = File.method(:read)
      with_env("HIVE_HOME" => dir) do
        with_replaced_singleton_method(File, :read, lambda { |path, *args, **kwargs|
          raise Errno::EACCES if path == pid_file

          original.call(path, *args, **kwargs)
        }) do
          assert_nil migrate_command("/tmp/project").send(:read_daemon_pid)
        end
      end
    end
  end

  def test_read_daemon_pid_returns_nil_when_pid_file_stat_fails
    with_tmp_dir do |dir|
      pid_file = File.join(dir, ".daemon.pid")
      File.write(pid_file, { "pid" => 4321 }.to_yaml)
      original = File.method(:exist?)
      with_env("HIVE_HOME" => dir) do
        with_replaced_singleton_method(File, :exist?, lambda { |path|
          raise Errno::EACCES if path == pid_file

          original.call(path)
        }) do
          assert_nil migrate_command("/tmp/project").send(:read_daemon_pid)
        end
      end
    end
  end

  def test_daemon_alive_classifies_signal_results
    migrate = migrate_command("/tmp/project")

    with_replaced_singleton_method(Process, :kill, lambda { |_signal, _pid| 1 }) do
      assert migrate.send(:daemon_alive?, 1234)
    end
    with_replaced_singleton_method(Process, :kill, lambda { |_signal, _pid| raise Errno::ESRCH }) do
      refute migrate.send(:daemon_alive?, 1234)
    end
    with_replaced_singleton_method(Process, :kill, lambda { |_signal, _pid| raise Errno::EPERM }) do
      assert migrate.send(:daemon_alive?, 1234)
    end
  end

  def test_managed_workflow_cleanup_commits_each_unique_workflow_path
    calls = []
    ops = Object.new
    ops.define_singleton_method(:hive_commit) { |**kwargs| calls << kwargs }
    operations = [ "writing", "architecture", "writing" ].map do |name|
      Struct.new(:workflow).new(name)
    end

    with_replaced_singleton_method(Hive::GitOps, :new, ->(*) { ops }) do
      with_replaced_singleton_method(Hive::Lock, :with_commit_lock, ->(_path, &block) { block.call }) do
        migrate_command("/tmp/project").send(
          :commit_managed_workflow_cleanup, "/tmp/project/.hive-state", operations
        )
      end
    end

    assert_equal [ "workflows/architecture", "workflows/writing" ], calls.first.fetch(:pathspecs)
  end

  def test_managed_recovery_marker_path_does_not_reenter_the_workflow_mutation_lock
    with_tmp_dir do |project|
      stages = File.join(project, ".hive-state", "stages")
      folder = write_task_folder(stages, "1-inbox", "managed-writing-260813-abcd")
      pin = {
        workflow_commit: "a" * 40,
        workflow_manifest_digest: "b" * 64,
        workflow_configuration_digest: "c" * 64
      }
      Hive::TaskMeta.write(
        folder, id: 42, slug: File.basename(folder), display_name: "Managed writing",
        workflow: "writing", **pin
      )
      workflow = migration_workflow("inbox", "review")
      calls = []
      store = Object.new
      store.define_singleton_method(:workflow) do |name, commit, digest, configuration_digest:, cfg:,
                                                     verify_profiles:|
        calls << [ name, commit, digest, configuration_digest, cfg, verify_profiles ]
        workflow
      end
      command = migrate_command(project)

      with_replaced_singleton_method(Hive::Task, :new, lambda { |_folder|
        raise "runtime task loading would re-enter the managed mutation lock"
      }) do
        assert_equal File.join(folder, "inbox.md"), command.send(
          :recovery_state_file, folder,
          managed_store: store,
          cfg: { "project_name" => "writing" }
        )
      end

      assert_equal false, calls.first.last
      assert_equal pin.values, calls.first.values_at(1, 2, 3)
    end
  end

  def test_unpinned_recovery_marker_path_uses_the_generation_captured_before_the_mutation_lock
    with_tmp_dir do |project|
      stages = File.join(project, ".hive-state", "stages")
      folder = write_task_folder(stages, "1-inbox", "legacy-coding-260813-abcd")
      generation = Object.new
      task = Struct.new(:state_file).new(File.join(folder, "idea.md"))
      calls = []

      with_replaced_singleton_method(Hive::Task, :new, lambda { |candidate, workflow_generation:|
        calls << [ candidate, workflow_generation ]
        task
      }) do
        assert_equal task.state_file, migrate_command(project).send(
          :recovery_state_file, folder, workflow_generation: generation
        )
      end

      assert_equal [ [ folder, generation ] ], calls
    end
  end

  def test_managed_recovery_marker_path_skips_a_stage_missing_from_its_pinned_descriptor
    with_tmp_dir do |project|
      stages = File.join(project, ".hive-state", "stages")
      folder = write_task_folder(stages, "1-inbox", "removed-stage-260813-abcd")
      Hive::TaskMeta.write(
        folder, id: 42, slug: File.basename(folder), display_name: "Removed stage",
        workflow: "writing", workflow_commit: "a" * 40,
        workflow_manifest_digest: "b" * 64, workflow_configuration_digest: "c" * 64
      )
      workflow = migration_workflow("review")
      store = Object.new
      store.define_singleton_method(:workflow) do |*_args, **_kwargs|
        workflow
      end

      assert_nil migrate_command(project).send(
        :recovery_state_file, folder, managed_store: store, cfg: {}
      )
    end
  end

  def test_recovery_marker_path_skips_an_invalid_unpinned_task
    with_tmp_dir do |project|
      folder = File.join(
        project, ".hive-state", "stages", "1-inbox", "invalid-task-260813-abcd"
      )
      error = Hive::InvalidTaskPath.new("unknown workflow")

      with_replaced_singleton_method(Hive::Task, :new, ->(*) { raise error }) do
        assert_nil migrate_command(project).send(:recovery_state_file, folder)
      end
    end
  end

  def test_managed_workflow_cleanup_warns_when_its_state_commit_fails
    ops = Object.new
    ops.define_singleton_method(:hive_commit) { |**| raise Hive::GitError, "commit blocked" }
    operation = Struct.new(:workflow).new("writing")

    _out, err = capture_io do
      with_replaced_singleton_method(Hive::GitOps, :new, ->(*) { ops }) do
        with_replaced_singleton_method(Hive::Lock, :with_commit_lock, ->(_path, &block) { block.call }) do
          migrate_command("/tmp/project").send(
            :commit_managed_workflow_cleanup, "/tmp/project/.hive-state", [ operation ]
          )
        end
      end
    end

    assert_includes err, "managed workflow cleanup could not be committed"
  end

  def test_managed_workflow_messages_cover_singular_tasks_without_stage_moves
    command = migrate_command("/tmp/project")

    assert_equal(
      "hive: migrate complete (0 tasks moved, 1 managed workflow task migrated)",
      command.send(
        :migration_complete_message, [], backfilled_count: 0,
        recovery_marker_count: 0, workflow_task_count: 1, workflow_moved_count: 0
      )
    )
    assert_equal(
      "hive: migrate migrated 1 managed workflow task",
      command.send(
        :migration_no_move_message, config_changed: false, backfilled_count: 0,
        workflow_task_count: 1, workflow_moved_count: 0
      )
    )
  end

  def test_complete_message_counts_backfilled_plan_review_requirements
    command = migrate_command("/tmp/project")

    assert_equal(
      "hive: migrate complete (0 tasks moved, 1 plan review requirement added)",
      command.send(
        :migration_complete_message, [], backfilled_count: 0,
        recovery_marker_count: 0, workflow_task_count: 0, workflow_moved_count: 0,
        plan_review_requirement_count: 1
      )
    )
    assert_equal(
      "hive: migrate complete (0 tasks moved, 2 plan review requirements added)",
      command.send(
        :migration_complete_message, [], backfilled_count: 0,
        recovery_marker_count: 0, workflow_task_count: 0, workflow_moved_count: 0,
        plan_review_requirement_count: 2
      )
    )
  end

  def test_legacy_reviewer_rewrite_reports_invalid_yaml_as_config_error
    error = assert_raises(Hive::ConfigError) do
      migrate_command("/tmp/project").send(
        :rewrite_legacy_root_reviewers,
        "reviewers: [unterminated\n",
        "/tmp/project/.hive-state/config.yml"
      )
    end

    assert_includes error.message, "is not valid YAML"
  end

  def migrate_command(project_path, display_name_generator: NoopDisplayNameGenerator,
                      **options)
    prepare_test_runtime_project(project_path)
    options[:global_migration] = -> { } unless options.key?(:global_migration)
    Hive::Commands::Migrate.new(
      project_path,
      display_name_generator: display_name_generator,
      **options
    )
  end

  def activate_control_plane(home)
    activate_test_control_plane(home)
  end

  def fake_daemon_service_installer(available:, &restart)
    installer = Object.new
    installer.define_singleton_method(:service_lifecycle_state) do
      { "service_manager_available" => available }
    end
    installer.define_singleton_method(:restart!) do
      restart ? restart.call : true
    end
    installer
  end

  def patrol_fix_source_snapshot
    Hive::PatrolFix::SourceSnapshot.build(
      engine: "ordinary_patrol", identity: "finding-1", title: "Repair refresh",
      summary: "Refresh fails", target_revision: "1" * 40,
      evidence: [ "Reachable failure" ], affected_code: [ "lib/demo.rb" ],
      reproduction_guidance: "Run focused test", discovery_run: "run-1",
      semantic_lineage: [ "refresh" ], aliases: [], external_issues: [],
      existing_pull_requests: [], accepted_at: "2026-08-23T12:00:00Z"
    )
  end

  def migration_workflow(*stage_names)
    Hive::Workflow.new(
      id: :writing,
      stages: stage_names.each_with_index.map do |name, index|
        Hive::Workflow::Stage.new(
          name: name, index: index + 1, state_file: "#{name}.md", kind: :agent
        )
      end
    )
  end

  def write_task_folder(stages, stage, slug, created_at: "2026-06-03T10:00:00Z", idea: true)
    folder = File.join(stages, stage, slug)
    FileUtils.mkdir_p(folder)
    if idea
      File.write(File.join(folder, "idea.md"), <<~MARKDOWN)
        ---
        slug: #{slug}
        created_at: #{created_at}
        ---

        Test idea
      MARKDOWN
    else
      File.write(File.join(folder, "task.md"), "x\n")
    end
    folder
  end
end
