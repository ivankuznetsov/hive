require "test_helper"
require "json"
require "set"
require "hive/babysitter/project_tick"
require "hive/babysitter/logger"

class BabysitterProjectTickTest < Minitest::Test
  include HiveTestHelper

  def project_entry(dir)
    { "name" => "demo", "path" => dir, "hive_state_path" => File.join(dir, ".hive-state") }
  end

  def write_config(dir, babysitter:)
    FileUtils.mkdir_p(File.join(dir, ".hive-state"))
    File.write(File.join(dir, ".hive-state", "config.yml"), { "babysitter" => babysitter }.to_yaml)
  end

  def make_logger(dir)
    Hive::Babysitter::Logger.new(path: File.join(dir, ".hive-state", "babysitter", "log.jsonl"))
  end

  def test_filters_ignored_labels_and_limits_to_oldest_updated_prs
    with_tmp_dir do |dir|
      project = project_entry(dir)
      write_config(
        dir,
        babysitter: {
          "enabled" => true,
          "labels_ignore" => %w[wip do-not-merge draft],
          "max_concurrent_prs" => 2
        }
      )
      prs = [
        { "number" => 1, "labels" => [ { "name" => "wip" } ], "updatedAt" => "2026-05-26T12:00:00Z" },
        { "number" => 2, "labels" => [], "updatedAt" => "2026-05-26T10:00:00Z" },
        { "number" => 3, "labels" => [], "updatedAt" => "2026-05-26T11:00:00Z" },
        { "number" => 4, "labels" => [], "updatedAt" => "2026-05-26T09:00:00Z" }
      ]
      called = []
      logger = make_logger(dir)

      with_replaced_singleton_method(Hive::Gh, :list_open_prs, ->(_path, **_kwargs) { prs }) do
        with_replaced_singleton_method(Hive::Babysitter::PrFixer, :run, lambda { |pr, _project, _cfg, **_kwargs|
          called << pr["number"]
          :success
        }) do
          summary = Hive::Babysitter::ProjectTick.run(project, dry_run: true, logger: logger, inflight: Set.new)
          assert_equal({ total: 2, fixed: 2, untouched: 0, needs_human: 0 }, summary)
        end
      end

      assert_equal [ 4, 2 ], called
      events = File.readlines(File.join(project.fetch("hive_state_path"), "babysitter", "events.jsonl")).map { |line| JSON.parse(line) }
      assert events.any? { |event| event["action"] == "skipped" && event["outcome"] == "label_ignored" && event["pr"] == 1 }
      assert File.exist?(File.join(project.fetch("hive_state_path"), "babysitter", "status.md"))
    ensure
      logger&.close
    end
  end

  def test_problematic_merge_states_are_selected_before_older_neutral_prs
    with_tmp_dir do |dir|
      project = project_entry(dir)
      write_config(
        dir,
        babysitter: {
          "enabled" => true,
          "labels_ignore" => [],
          "max_concurrent_prs" => 2
        }
      )
      prs = [
        { "number" => 10, "labels" => [], "mergeStateStatus" => "CLEAN", "updatedAt" => "2026-05-26T09:00:00Z" },
        { "number" => 11, "labels" => [], "mergeStateStatus" => "UNKNOWN", "updatedAt" => "2026-05-26T10:00:00Z" },
        { "number" => 341, "labels" => [], "mergeStateStatus" => "DIRTY", "updatedAt" => "2026-05-27T12:00:00Z" },
        { "number" => 12, "labels" => [], "mergeStateStatus" => "CLEAN", "updatedAt" => "2026-05-26T08:00:00Z" }
      ]
      called = []
      logger = make_logger(dir)

      with_replaced_singleton_method(Hive::Gh, :list_open_prs, ->(_path, **_kwargs) { prs }) do
        with_replaced_singleton_method(Hive::Babysitter::PrFixer, :run, lambda { |pr, _project, _cfg, **_kwargs|
          called << pr["number"]
          :success
        }) do
          summary = Hive::Babysitter::ProjectTick.run(project, dry_run: true, logger: logger, inflight: Set.new)
          assert_equal({ total: 2, fixed: 2, untouched: 0, needs_human: 0 }, summary)
        end
      end

      assert_equal [ 341, 11 ], called
    ensure
      logger&.close
    end
  end

  def test_skips_draft_prs_before_spawning_agent
    with_tmp_dir do |dir|
      project = project_entry(dir)
      write_config(
        dir,
        babysitter: {
          "enabled" => true,
          "labels_ignore" => %w[wip do-not-merge draft],
          "max_concurrent_prs" => 2
        }
      )
      prs = [
        { "number" => 10, "isDraft" => true, "labels" => [], "updatedAt" => "2026-05-26T09:00:00Z" },
        { "number" => 11, "isDraft" => false, "labels" => [], "updatedAt" => "2026-05-26T10:00:00Z" }
      ]
      called = []
      logger = make_logger(dir)

      with_replaced_singleton_method(Hive::Gh, :list_open_prs, ->(_path, **_kwargs) { prs }) do
        with_replaced_singleton_method(Hive::Babysitter::PrFixer, :run, lambda { |pr, _project, _cfg, **_kwargs|
          called << pr["number"]
          :dry_run
        }) do
          summary = Hive::Babysitter::ProjectTick.run(project, dry_run: true, logger: logger, inflight: Set.new)
          assert_equal({ total: 1, fixed: 0, untouched: 1, needs_human: 0 }, summary)
        end
      end

      assert_equal [ 11 ], called
      events = File.readlines(File.join(project.fetch("hive_state_path"), "babysitter", "events.jsonl")).map { |line| JSON.parse(line) }
      assert events.any? { |event| event["action"] == "skipped" && event["outcome"] == "draft_pr" && event["pr"] == 10 }
    ensure
      logger&.close
    end
  end

  def write_task_pointer(dir, stage_dir, slug, branch)
    task_dir = File.join(dir, ".hive-state", "stages", stage_dir, slug)
    FileUtils.mkdir_p(task_dir)
    File.write(File.join(task_dir, "worktree.yml"),
               { "branch" => branch, "path" => File.join(dir, "wt", slug) }.to_yaml)
    task_dir
  end

  # A PR whose branch an active pipeline task still owns (per hive-state) must
  # be skipped — even though it is non-draft (finalize un-drafted it). This is
  # the babysitter-vs-pipeline rebase race fix: git/hive-state is the source of
  # truth, not the GitHub draft flag.
  def test_skips_prs_owned_by_an_active_pipeline_task
    with_tmp_dir do |dir|
      project = project_entry(dir)
      write_config(dir, babysitter: { "enabled" => true, "labels_ignore" => [], "max_concurrent_prs" => 5 })
      write_task_pointer(dir, "6-review", "patrol-fix-thing", "hive-patrol/owned-branch")
      # A pre-execute task (no worktree.yml) in an active stage must not crash
      # the scan and contributes no branch.
      FileUtils.mkdir_p(File.join(dir, ".hive-state", "stages", "3-plan", "no-worktree-yet"))
      prs = [
        { "number" => 20, "headRefName" => "hive-patrol/owned-branch", "isDraft" => false, "labels" => [], "updatedAt" => "2026-05-26T10:00:00Z" },
        { "number" => 21, "headRefName" => "some/other-branch", "isDraft" => false, "labels" => [], "updatedAt" => "2026-05-26T11:00:00Z" }
      ]
      called = []
      logger = make_logger(dir)

      with_replaced_singleton_method(Hive::Gh, :list_open_prs, ->(_path, **_kwargs) { prs }) do
        with_replaced_singleton_method(Hive::Babysitter::PrFixer, :run, lambda { |pr, _project, _cfg, **_kwargs|
          called << pr["number"]
          :success
        }) do
          summary = Hive::Babysitter::ProjectTick.run(project, dry_run: true, logger: logger, inflight: Set.new)
          assert_equal({ total: 1, fixed: 1, untouched: 0, needs_human: 0 }, summary)
        end
      end

      assert_equal [ 21 ], called, "only the PR not owned by an active task may be touched"
      events = File.readlines(File.join(project.fetch("hive_state_path"), "babysitter", "events.jsonl")).map { |line| JSON.parse(line) }
      assert events.any? { |e| e["action"] == "skipped" && e["outcome"] == "pipeline_owned" && e["pr"] == 20 },
             "the pipeline-owned PR must be skipped with outcome pipeline_owned"
    ensure
      logger&.close
    end
  end

  # A task in the terminal done stage no longer owns its branch — its PR is
  # finished with the pipeline, so the babysitter may manage it again.
  def test_done_stage_task_does_not_protect_its_branch
    with_tmp_dir do |dir|
      project = project_entry(dir)
      write_config(dir, babysitter: { "enabled" => true, "labels_ignore" => [], "max_concurrent_prs" => 5 })
      write_task_pointer(dir, "9-done", "finished-task", "feature/done-branch")
      prs = [
        { "number" => 30, "headRefName" => "feature/done-branch", "isDraft" => false, "labels" => [], "updatedAt" => "2026-05-26T10:00:00Z" }
      ]
      called = []
      logger = make_logger(dir)

      with_replaced_singleton_method(Hive::Gh, :list_open_prs, ->(_path, **_kwargs) { prs }) do
        with_replaced_singleton_method(Hive::Babysitter::PrFixer, :run, lambda { |pr, _project, _cfg, **_kwargs|
          called << pr["number"]
          :success
        }) do
          Hive::Babysitter::ProjectTick.run(project, dry_run: true, logger: logger, inflight: Set.new)
        end
      end

      assert_equal [ 30 ], called, "a done-stage task must not shield its branch from the babysitter"
    ensure
      logger&.close
    end
  end

  # A malformed worktree.yml (non-hash) must not crash the scan; that task
  # simply contributes no owned branch and its PR is processed normally.
  def test_malformed_worktree_pointer_does_not_crash_ownership_scan
    with_tmp_dir do |dir|
      project = project_entry(dir)
      write_config(dir, babysitter: { "enabled" => true, "labels_ignore" => [], "max_concurrent_prs" => 5 })
      bad = File.join(dir, ".hive-state", "stages", "6-review", "broken-task")
      FileUtils.mkdir_p(bad)
      File.write(File.join(bad, "worktree.yml"), "- not\n- a\n- hash\n")
      prs = [
        { "number" => 40, "headRefName" => "feature/whatever", "isDraft" => false, "labels" => [], "updatedAt" => "2026-05-26T10:00:00Z" }
      ]
      called = []
      logger = make_logger(dir)

      with_replaced_singleton_method(Hive::Gh, :list_open_prs, ->(_path, **_kwargs) { prs }) do
        with_replaced_singleton_method(Hive::Babysitter::PrFixer, :run, lambda { |pr, _project, _cfg, **_kwargs|
          called << pr["number"]
          :success
        }) do
          Hive::Babysitter::ProjectTick.run(project, dry_run: true, logger: logger, inflight: Set.new)
        end
      end

      assert_equal [ 40 ], called, "a malformed pointer must be skipped gracefully, not crash the tick"
    ensure
      logger&.close
    end
  end

  def test_rebased_and_conflict_outcomes_are_tallied
    with_tmp_dir do |dir|
      project = project_entry(dir)
      write_config(dir, babysitter: { "enabled" => true, "labels_ignore" => [], "max_concurrent_prs" => 2 })
      logger = make_logger(dir)
      prs = [
        { "number" => 20, "labels" => [], "updatedAt" => "2026-05-26T10:00:00Z" },
        { "number" => 21, "labels" => [], "updatedAt" => "2026-05-26T11:00:00Z" }
      ]
      outcomes = { 20 => :rebased, 21 => :rebase_conflict }

      with_replaced_singleton_method(Hive::Gh, :list_open_prs, ->(_path, **_kwargs) { prs }) do
        with_replaced_singleton_method(Hive::Babysitter::PrFixer, :run, ->(pr, *_args, **_kwargs) { outcomes.fetch(pr["number"]) }) do
          summary = Hive::Babysitter::ProjectTick.run(project, dry_run: false, logger: logger, inflight: Set.new)
          assert_equal({ total: 2, fixed: 1, untouched: 0, needs_human: 1 }, summary)
        end
      end
    ensure
      logger&.close
    end
  end

  def test_gh_error_emits_event_and_does_not_spawn_agent
    with_tmp_dir do |dir|
      project = project_entry(dir)
      write_config(dir, babysitter: { "enabled" => true })
      logger = make_logger(dir)
      spawned = false

      with_replaced_singleton_method(Hive::Gh, :list_open_prs, ->(_path, **_kwargs) { raise Hive::GhError, "api down" }) do
        with_replaced_singleton_method(Hive::Babysitter::PrFixer, :run, ->(*_args, **_kwargs) { spawned = true }) do
          summary = Hive::Babysitter::ProjectTick.run(project, dry_run: false, logger: logger, inflight: Set.new)
          assert_equal({ total: 0, fixed: 0, untouched: 0, needs_human: 0 }, summary)
        end
      end

      refute spawned
      event = JSON.parse(File.read(File.join(project.fetch("hive_state_path"), "babysitter", "events.jsonl")))
      assert_equal "list-prs", event.fetch("action")
      assert_equal "gh-error", event.fetch("outcome")
    ensure
      logger&.close
    end
  end

  def test_inflight_prs_are_not_spawned
    with_tmp_dir do |dir|
      project = project_entry(dir)
      write_config(dir, babysitter: { "enabled" => true, "max_concurrent_prs" => 2 })
      logger = make_logger(dir)
      prs = [
        { "number" => 7, "labels" => [], "updatedAt" => "2026-05-26T10:00:00Z" }
      ]
      called = []
      inflight = Set.new([ [ "demo", 7 ] ])

      with_replaced_singleton_method(Hive::Gh, :list_open_prs, ->(_path, **_kwargs) { prs }) do
        with_replaced_singleton_method(Hive::Babysitter::PrFixer, :run, lambda { |pr, *_args, **_kwargs|
          called << pr["number"]
        }) do
          Hive::Babysitter::ProjectTick.run(project, dry_run: false, logger: logger, inflight: inflight)
        end
      end

      assert_empty called
    ensure
      logger&.close
    end
  end
end
