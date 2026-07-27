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
    with_tmp_global_config do
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

        out, _err = capture_io { migrate_command(dir).call }

        assert File.directory?(File.join(stages, "6-review", "old-review-260513-abcd"))
        assert File.directory?(File.join(stages, "8-finalize", "old-pr-260513-abcd"))
        assert File.directory?(File.join(stages, "9-done", "old-done-260513-abcd"))
        assert_includes out, "1 recovery marker upgraded"
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
      workflow_configuration_count: 4
    )

    assert_equal(
      "hive: migrate project state (2 ids, 3 recovery markers, " \
      "4 managed workflow pins)",
      message
    )
  end

  def test_managed_workflow_pin_only_commit_message
    message = migrate_command("/tmp/project").send(
      :migrate_commit_message,
      [],
      config_only: false,
      workflow_configuration_count: 1
    )

    assert_equal "hive: migrate managed workflow pins (1 task)", message
  end

  def test_managed_workflow_pin_no_move_message
    message = migrate_command("/tmp/project").send(
      :migration_no_move_message,
      config_changed: false,
      backfilled_count: 0,
      workflow_configuration_count: 2
    )

    assert_equal "hive: migrate updated 2 managed workflow pins", message
  end

  def test_complete_message_reports_every_migration_count
    message = migrate_command("/tmp/project").send(
      :migration_complete_message,
      [ [ "5-review", "6-review", "task-a" ], [ "6-pr", "8-finalize", "task-b" ] ],
      backfilled_count: 2,
      recovery_marker_count: 3,
      workflow_configuration_count: 4
    )

    assert_equal(
      "hive: migrate complete (2 tasks moved, 2 ids backfilled, " \
      "3 recovery markers upgraded, 4 managed workflow pins updated)",
      message
    )
  end

  def test_rebinds_same_generation_managed_tasks_to_the_selected_configuration
    with_tmp_dir do |project|
      hive_state = File.join(project, ".hive-state")
      stages = File.join(hive_state, "stages")
      folder = write_task_folder(
        stages, "7-deliver", "managed-writing-260726-abcd"
      )
      old_digest = "a" * 64
      selected_digest = "b" * 64
      commit = "c" * 40
      manifest = "d" * 64
      Hive::TaskMeta.write(
        folder,
        id: 42,
        slug: File.basename(folder),
        display_name: "Managed writing",
        depends_on: "source-task-260725-abcd",
        workflow: "writing",
        base_branch: "launch",
        workflow_commit: commit,
        workflow_manifest_digest: manifest,
        workflow_configuration_digest: old_digest
      )

      calls = []
      store = Object.new
      store.define_singleton_method(:selected) do |name, cfg:|
        calls << [ :selected, name, cfg ]
        {
          "source_commit" => commit,
          "manifest_digest" => manifest,
          "configuration_digest" => selected_digest
        }
      end
      store.define_singleton_method(:workflow) do |name, source, digest, **kwargs|
        calls << [ :workflow, name, source, digest, kwargs ]
        Object.new
      end
      store.define_singleton_method(:cleanup_unreferenced) do |name|
        calls << [ :cleanup, name ]
        []
      end
      command = migrate_command(
        project,
        managed_store_factory: ->(_path) { store },
        config_loader: ->(_path) { { "project_name" => "writing" } }
      )

      count = command.send(
        :migrate_managed_workflow_configuration_pins, stages, hive_state
      )

      assert_equal 1, count
      migrated = Hive::TaskMeta.read(folder)
      assert_equal selected_digest, migrated.fetch(:workflow_configuration_digest)
      assert_equal "source-task-260725-abcd", migrated.fetch(:depends_on)
      assert_equal "launch", migrated.fetch(:base_branch)
      assert_includes calls, [ :cleanup, "writing" ]
      workflow_call = calls.find { |entry| entry.first == :workflow }
      assert_equal selected_digest,
                   workflow_call.last.fetch(:configuration_digest)
    end
  end

  def test_preserves_managed_tasks_pinned_to_another_package_generation
    with_tmp_dir do |project|
      hive_state = File.join(project, ".hive-state")
      stages = File.join(hive_state, "stages")
      folder = write_task_folder(
        stages, "7-deliver", "older-writing-260726-abcd"
      )
      pinned_digest = "a" * 64
      Hive::TaskMeta.write(
        folder,
        id: 43,
        slug: File.basename(folder),
        display_name: "Older writing",
        workflow: "writing",
        workflow_commit: "c" * 40,
        workflow_manifest_digest: "d" * 64,
        workflow_configuration_digest: pinned_digest
      )

      cleanup_calls = []
      store = Object.new
      store.define_singleton_method(:selected) do |_name, cfg:|
        {
          "source_commit" => "e" * 40,
          "manifest_digest" => "f" * 64,
          "configuration_digest" => "b" * 64
        }
      end
      store.define_singleton_method(:cleanup_unreferenced) do |_name|
        cleanup_calls << true
      end
      command = migrate_command(
        project,
        managed_store_factory: ->(_path) { store },
        config_loader: ->(_path) { {} }
      )

      count = command.send(
        :migrate_managed_workflow_configuration_pins, stages, hive_state
      )

      assert_equal 0, count
      assert_empty cleanup_calls
      assert_equal pinned_digest,
                   Hive::TaskMeta.read(folder).fetch(:workflow_configuration_digest)
    end
  end

  def test_preflights_all_selected_configurations_before_rewriting_tasks
    with_tmp_dir do |project|
      hive_state = File.join(project, ".hive-state")
      stages = File.join(hive_state, "stages")
      old_digest = "a" * 64
      selected_digest = "b" * 64
      manifest = "d" * 64
      %w[a-writing b-broken].each_with_index do |name, index|
        folder = write_task_folder(
          stages, "7-deliver", "#{name}-260726-abcd"
        )
        Hive::TaskMeta.write(
          folder,
          id: 50 + index,
          slug: File.basename(folder),
          display_name: name,
          workflow: name,
          workflow_commit: "c" * 40,
          workflow_manifest_digest: manifest,
          workflow_configuration_digest: old_digest
        )
      end

      store = Object.new
      store.define_singleton_method(:selected) do |name, cfg:|
        {
          "source_commit" => "c" * 40,
          "manifest_digest" => manifest,
          "configuration_digest" => selected_digest,
          "name" => name,
          "cfg" => cfg
        }
      end
      store.define_singleton_method(:workflow) do |name, *_args, **_kwargs|
        raise Hive::ConfigError, "selected profile is unavailable" if name == "b-broken"

        Object.new
      end
      store.define_singleton_method(:cleanup_unreferenced) do |_name|
        raise "cleanup must not run after failed preflight"
      end
      command = migrate_command(
        project,
        managed_store_factory: ->(_path) { store },
        config_loader: ->(_path) { {} }
      )

      error = assert_raises(Hive::ConfigError) do
        command.send(
          :migrate_managed_workflow_configuration_pins, stages, hive_state
        )
      end

      assert_includes error.message, "selected profile is unavailable"
      %w[a-writing b-broken].each do |name|
        folder = File.join(stages, "7-deliver", "#{name}-260726-abcd")
        assert_equal old_digest,
                     Hive::TaskMeta.read(folder).fetch(:workflow_configuration_digest)
      end
    end
  end

  def test_backfills_missing_registered_repository_identity_once
    with_tmp_global_config do
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
    with_tmp_global_config do
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
    with_tmp_global_config do
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
    with_tmp_global_config do
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
    with_tmp_global_config do
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
    with_tmp_global_config do
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
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }

        out, _err = capture_io { migrate_command(dir).call }

        assert_includes out, "target stage directories look already-migrated"
      end
    end
  end

  def test_migrate_reports_plain_noop_when_legacy_dirs_only_have_non_slug_entries
    with_tmp_global_config do
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
    with_tmp_global_config do
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
    with_tmp_global_config do
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
    with_tmp_global_config do
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

  def test_migrate_moves_top_level_reviewers_under_review_without_losing_comments
    with_tmp_global_config do
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
    with_tmp_global_config do
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
    with_tmp_global_config do
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
    with_tmp_global_config do
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
    with_tmp_global_config do
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
    with_tmp_global_config do
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
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        stages = File.join(dir, ".hive-state", "stages")
        later = write_task_folder(stages, "2-brainstorm", "later-task-260603-bbbb", created_at: "2026-06-03T12:00:00Z")
        earlier = write_task_folder(stages, "2-brainstorm", "early-task-260603-aaaa", created_at: "2026-06-03T11:00:00Z")
        no_idea = write_task_folder(stages, "2-brainstorm", "no-idea-260603-cccc", idea: false)

        out, _err = capture_io { migrate_command(dir).call }

        assert_includes out, "backfilled 3 task ids"
        assert_equal({ id: 1, slug: "early-task-260603-aaaa", display_name: nil, depends_on: nil, workflow: nil },
                     Hive::TaskMeta.read(earlier))
        assert_equal({ id: 2, slug: "later-task-260603-bbbb", display_name: nil, depends_on: nil, workflow: nil },
                     Hive::TaskMeta.read(later))
        assert_equal({ id: 3, slug: "no-idea-260603-cccc", display_name: nil, depends_on: nil, workflow: nil },
                     Hive::TaskMeta.read(no_idea))
        assert_equal 4, Hive::TaskCounter.peek
      end
    end
  end

  def test_migrate_upgrades_idless_recovery_markers_once
    with_tmp_global_config do
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
      with_tmp_global_config do
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
    with_tmp_global_config do
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
    with_tmp_global_config do
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
    with_tmp_global_config do
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
    with_tmp_global_config do
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

        capture_io { migrate_command(dir).call }

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
    with_tmp_global_config do
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

  def test_migrate_seeds_counter_above_existing_ids
    with_tmp_global_config do
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
        migrate.send(:commit_display_name_backfill, "/tmp/project/.hive-state", 2)
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
        migrate.send(:commit_display_name_backfill, "/tmp/project/.hive-state", 1)
      end

      assert_includes err, "hive: migrate display names (1 task)'"
      refute_includes err, "1 tasks"
    end
  end

  def test_restart_daemon_uses_systemctl_when_available
    migrate = migrate_command("/tmp/project")
    calls = []
    migrate.define_singleton_method(:read_daemon_pid) { 1234 }
    migrate.define_singleton_method(:daemon_alive?) { |_pid| true }
    migrate.define_singleton_method(:systemctl_available?) { true }
    migrate.define_singleton_method(:system) do |*args, **kwargs|
      calls << [ args, kwargs ]
      true
    end

    out, err = capture_io { migrate.send(:restart_daemon_if_running!) }

    assert_equal [ [ [ "systemctl", "--user", "restart", "hive-daemon" ], { out: File::NULL, err: File::NULL } ] ], calls
    assert_includes out, "restarted hive-daemon (pid 1234)"
    assert_empty err
  end

  def test_restart_daemon_warns_when_systemctl_restart_fails
    migrate = migrate_command("/tmp/project")
    migrate.define_singleton_method(:read_daemon_pid) { 1234 }
    migrate.define_singleton_method(:daemon_alive?) { |_pid| true }
    migrate.define_singleton_method(:systemctl_available?) { true }
    migrate.define_singleton_method(:system) { |*_args, **_kwargs| false }

    _out, err = capture_io { migrate.send(:restart_daemon_if_running!) }

    assert_includes err, "systemctl --user restart hive-daemon` failed"
  end

  def test_restart_daemon_warns_when_systemctl_is_unavailable
    migrate = migrate_command("/tmp/project")
    migrate.define_singleton_method(:read_daemon_pid) { 1234 }
    migrate.define_singleton_method(:daemon_alive?) { |_pid| true }
    migrate.define_singleton_method(:systemctl_available?) { false }

    _out, err = capture_io { migrate.send(:restart_daemon_if_running!) }

    assert_includes err, "restart it manually so its in-memory stage layout refreshes"
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

  def test_systemctl_available_returns_false_when_system_call_cannot_spawn
    migrate = migrate_command("/tmp/project")
    migrate.define_singleton_method(:system) { |*_args, **_kwargs| raise Errno::ENOENT }

    refute migrate.send(:systemctl_available?)
  end

  def migrate_command(project_path, display_name_generator: NoopDisplayNameGenerator,
                      **options)
    Hive::Commands::Migrate.new(
      project_path,
      display_name_generator: display_name_generator,
      **options
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
