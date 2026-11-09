require "test_helper"
require "fileutils"
require "hive/pull_request_outcome"
require "hive/stages/review"
require "hive/task"

class PullRequestOutcomeTest < Minitest::Test
  include HiveTestHelper

  PR_URL = "https://github.com/acme/demo/pull/23".freeze

  def test_latest_matching_observation_wins_and_maps_watcher_states
    with_review_task do |folder|
      records = [
        observation("pr_observed", "pr_state" => "open"),
        observation("pr_observed", "pr_state" => "delivered_elsewhere"),
        observation("check_observed", "pr_state" => "open"),
        observation("pr_observed", "pr_state" => "open", "pr_url" => "https://github.com/acme/demo/pull/9"),
        { "payload" => "not a hash" }
      ]
      with_journal(records) do
        outcome = Hive::PullRequestOutcome.latest(folder)

        assert_equal Hive::PullRequestOutcome::MERGED, outcome.state
        assert_equal PR_URL, outcome.pr_url
        assert_predicate outcome, :merged?
        assert_predicate outcome, :settled?
      end
    end
  end

  def test_publication_cache_merge_and_closed_states_are_recognized
    with_review_task do |folder|
      with_journal([ observation("merge_observed", "pr_state" => "merged", "merge_state" => "merged") ]) do
        assert_predicate Hive::PullRequestOutcome.latest(folder), :merged?
      end
      with_journal([ observation("pr_observed", "pr_state" => "closed") ]) do
        outcome = Hive::PullRequestOutcome.latest(folder)
        assert_predicate outcome, :closed_unmerged?
        assert_predicate outcome, :settled?
        refute_predicate outcome, :merged?
      end
      with_journal([ observation("pr_observed", "pr_state" => "open") ]) do
        refute_predicate Hive::PullRequestOutcome.latest(folder), :settled?
      end
    end
  end

  def test_unavailable_observations_fail_safe_to_nil
    with_review_task(pr_url: nil) do |folder|
      assert_nil Hive::PullRequestOutcome.latest(folder), "no pr.md binding"
    end
    with_review_task do |folder|
      assert_nil Hive::PullRequestOutcome.latest(folder), "no journal yet"
      with_journal([ observation("pr_observed", "pr_state" => "unknown") ]) do
        assert_nil Hive::PullRequestOutcome.latest(folder), "unrecognized state"
      end
      File.write(File.join(folder, Hive::TaskJournal::JOURNAL_BASENAME), "{not json\n")
      assert_nil Hive::PullRequestOutcome.latest(folder), "unreadable journal"
    end
  end

  def test_review_run_spawns_no_agent_for_a_merged_pull_request
    with_review_task do |folder|
      task = Hive::Task.new(folder)
      with_journal([ observation("pr_observed", "pr_state" => "merged") ]) do
        with_replaced_singleton_method(Hive::Stages::Review::CiFix, :run!, ->(**) { flunk "CI-fix must not run" }) do
          result = nil
          _out, err = capture_io { result = Hive::Stages::Review.run!(task, { "review" => {} }) }

          assert_equal({ commit: nil, status: :pull_request_merged }, result)
          assert_includes err, "--reason already_delivered --evidence #{PR_URL}"
          assert_equal :none, Hive::Markers.current(task.state_file).name
        end
      end
    end
  end

  def test_review_run_spawns_no_agent_for_a_closed_pull_request
    with_review_task do |folder|
      task = Hive::Task.new(folder)
      with_journal([ observation("pr_observed", "pr_state" => "closed_unmerged") ]) do
        result = nil
        _out, err = capture_io { result = Hive::Stages::Review.run!(task, { "review" => {} }) }

        assert_equal({ commit: nil, status: :pull_request_closed_unmerged }, result)
        assert_includes err, "closed without merging"
      end
    end
  end

  def test_review_run_with_open_pull_request_proceeds_to_existing_preconditions
    with_review_task do |folder|
      task = Hive::Task.new(folder)
      with_journal([ observation("pr_observed", "pr_state" => "open") ]) do
        error = assert_raises(SystemExit) do
          capture_io { Hive::Stages::Review.run!(task, { "review" => {} }) }
        end
        assert_equal 1, error.status, "an open PR reaches the worktree.yml precondition as before"
      end
    end
  end

  private

  def with_review_task(pr_url: PR_URL)
    with_tmp_dir do |root|
      folder = File.join(root, ".hive-state", "stages", "6-review", "merged-task")
      FileUtils.mkdir_p(File.join(folder, "reviews"))
      File.write(File.join(folder, "task.md"), "")
      File.write(File.join(folder, "pr.md"), "---\npr_url: #{pr_url}\n---\n") if pr_url
      yield folder
    end
  end

  def with_journal(records, &block)
    with_replaced_singleton_method(Hive::TaskProjection, :read_journal, ->(_path) { records }, &block)
  end

  def observation(kind, payload)
    { "payload" => { "activity_kind" => kind, "pr_url" => PR_URL }.merge(payload) }
  end
end
