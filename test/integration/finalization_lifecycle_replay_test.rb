require "test_helper"
require "hive/commands/init"
require "hive/conditions/transition_guard"
require "hive/finalization/reconciler"
require "hive/task_action"
require "hive/task_meta"
require_relative "../support/finalization_replay"

class FinalizationLifecycleReplayTest < Minitest::Test
  include HiveTestHelper

  FIXTURE = File.expand_path("../fixtures/incidents/topgreendeals-pr-295", __dir__)
  MERGED_AT = "2026-07-16T23:05:50Z"

  def test_pr_295_replays_restart_head_invalidation_disappearance_and_exactly_once_archive
    with_replay_project do |dir|
      ready = replay(dir).run(until_step: :ready_a)
      assert_equal "merge_ready", ready.projection.fetch("state")
      assert_equal 1, ready.jobs.length
      assert_event_count ready, "archive_ready", 0

      changed = replay(dir).run(until_step: :head_b)
      assert_equal "babysitter_active", changed.projection.fetch("state")
      assert_equal 2, changed.projection.fetch("head_generation")
      assert_nil changed.projection.dig("evidence", "merge_ready_event_id")
      assert_equal [ 1, 2, 3 ], changed.jobs.first.fetch("claims").map { |claim| claim["claim_fence"] }
      assert_event_count changed, "archive_ready", 0

      missing = replay(dir).run(until_step: :list_disappearance)
      assert_equal "merge_ready", missing.projection.fetch("state")
      assert_equal 4, missing.jobs.first.fetch("claims").last.fetch("claim_fence")
      assert_event_count missing, "archive_ready", 0

      merged = replay(dir).run(until_step: :merged)
      assert_equal "merged", merged.projection.fetch("state")
      assert_equal MERGED_AT, merged.projection.dig("evidence", "merged_at")
      assert_event_count merged, "archive_ready", 0

      archived = replay(dir).run
      assert_equal "archive_ready", archived.projection.fetch("state")
      assert_equal 1, archived.stage_moves
      assert_equal "9-done", File.basename(File.dirname(archived.task_folder))
      assert_event_count archived, "merged", 1
      assert_event_count archived, "archive_ready", 1
      assert_event_count archived, "cleanup_completed", 1
      assert_equal 1, archived.jobs.length

      replayed = replay(dir).run
      assert_equal 0, replayed.stage_moves
      assert_event_count replayed, "merged", 1
      assert_event_count replayed, "archive_ready", 1
      assert_event_count replayed, "cleanup_completed", 1
    end
  end

  def test_replay_resumes_from_claim_archive_move_and_cleanup_crash_boundaries
    with_replay_project do |dir|
      claimed = replay(dir).run(until_step: :crashed_claim)
      assert_equal "active", claimed.jobs.first.fetch("claims").last.fetch("state")

      ready = replay(dir).run(until_step: :archive_ready)
      assert_equal "archive_ready", ready.projection.fetch("state")
      assert_event_count ready, "archive_ready", 1

      moved = replay(dir).run(until_step: :stage_moved)
      assert_equal 1, moved.stage_moves
      assert File.directory?(moved.task_folder)

      error = assert_raises(RuntimeError) do
        replay(dir).run(crash_after_cleanup: :branch_deleted)
      end
      assert_includes error.message, "injected cleanup crash"
      records = Hive::TaskProjection.read_journal(File.join(moved.task_folder, "events.jsonl"))
      refute records.any? { |record| record["event_type"] == "cleanup_completed" }

      recovered = replay(dir).run
      assert_event_count recovered, "cleanup_completed", 1
    end
  end

  def test_closed_unmerged_terminal_snapshot_never_archives
    with_replay_project do |dir|
      blocked = replay(dir, terminal_response: "closed_head_b").run

      assert_equal "blocked", blocked.projection.fetch("state")
      assert_equal "closed_unmerged", blocked.projection.dig("blocker", "code")
      assert_event_count blocked, "archive_ready", 0
      assert_event_count blocked, "cleanup_completed", 0
      assert_equal "8-finalize", File.basename(File.dirname(blocked.task_folder))
    end
  end

  def test_fixture_digest_tampering_fails_before_replay
    with_tmp_dir do |copy|
      FileUtils.cp_r(FIXTURE, copy)
      bundle = File.join(copy, File.basename(FIXTURE))
      File.open(File.join(bundle, "github-responses.json"), "a") { |file| file.write("\n") }

      with_tmp_git_repo do |dir|
        error = assert_raises(HiveTestSupport::FinalizationReplay::InvalidFixture) do
          HiveTestSupport::FinalizationReplay.new(bundle, project_root: dir)
        end
        assert_includes error.message, "digest mismatch"
      end
    end
  end

  def test_legacy_summary_without_handoff_requires_finalize_repair
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        slug = "legacy-finalized-260717-aaaa"
        folder = File.join(dir, ".hive-state", "stages", "8-finalize", slug)
        FileUtils.mkdir_p(folder)
        Hive::TaskMeta.write(folder, id: "legacy-1", slug: slug, display_name: "Legacy finalized")
        File.write(File.join(folder, "summary.md"), "# Existing summary\n")
        File.write(File.join(folder, "pr.md"), <<~MD)
          ---
          pr_url: https://github.com/sanitized/example/pull/1
          ---

          <!-- COMPLETE pr_url=https://github.com/sanitized/example/pull/1 is_draft=false -->
        MD
        task = Hive::Task.new(folder)
        marker = Hive::Markers.current(task.state_file)
        projection = Hive::TaskProjection::Store.new(task_folder: folder).read(marker: marker)

        assert_equal "unfinalized", projection.to_h.dig("finalization", "state")
        assert_equal "rerun_finalize", projection.to_h.dig("finalization", "safe_action", "code")
        action = Hive::TaskAction.for(task, marker, projection: projection)
        assert_equal "ready_to_finalize", action.key
        assert_includes action.command, "hive finalize"
        assert_equal :not_eligible,
                     Hive::Finalization::Reconciler.new(task_folder: folder).reconcile.status
        assert_raises(Hive::WrongStage) { Hive::Conditions::TransitionGuard.validate!(task) }
      end
    end
  end

  private

  def replay(dir, terminal_response: "merged_head_b")
    HiveTestSupport::FinalizationReplay.new(
      FIXTURE, project_root: dir, terminal_response: terminal_response
    )
  end

  def with_replay_project
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        yield dir
      end
    end
  end

  def assert_event_count(result, type, expected)
    assert_equal expected, result.records.count { |record| record["event_type"] == type }
  end
end
