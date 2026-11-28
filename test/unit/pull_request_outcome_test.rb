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

  def test_internal_pr_review_ignores_stale_closed_a_journal_and_stops_on_settled_b_or_newer_bound_watcher
    require "hive/internal_pr_checkout"
    require "hive/attempts/contracts"
    oid_a = "a" * 40
    oid_b = "b" * 40
    with_tmp_dir do |root|
      folder = File.join(root, ".hive-state", "stages", "6-review", "adhoc-review-pr-23")
      FileUtils.mkdir_p(File.join(folder, "reviews"))
      FileUtils.mkdir_p(File.join(folder, "reviews", "archive", "internal-pr-reopen-gen1"))
      File.write(File.join(folder, "task.md"), "---\nsource: ad-hoc\n---\n\n# PR 23\n")
      File.write(File.join(folder, "pr.md"), <<~MD)
        ---
        source: ad-hoc
        pr_number: 23
        pr_url: #{PR_URL}
        head_oid: #{oid_b}
        base_ref_name: main
        head_ref_name: feat
        head_repository: acme/demo
        is_cross_repository: false
        pr_state: OPEN
        ---
      MD
      store = Hive::InternalPrCheckout::Store.new(folder)
      tx_id = "tx-gen2-0001"
      ret_label = "internal-pr-reopen-gen1"
      digest = Hive::InternalPrCheckout::Store.head_transition_digest(
        pr_url: PR_URL, pr_number: 23, branch: "hive/review/pr-23",
        reviewed_oid: oid_b, generation: 2, previous_generation: 1,
        retirement_label: ret_label, transaction_id: tx_id
      )
      store.write_current!(
        "schema" => Hive::InternalPrCheckout::Store::CURRENT_SCHEMA,
        "schema_version" => 1,
        "task_id" => "0023", "task_slug" => "adhoc-review-pr-23", "project" => File.basename(root),
        "pr_host" => "github.com", "pr_repository" => "acme/demo",
        "pr_number" => 23, "pr_url" => PR_URL,
        "base_ref_name" => "main", "head_ref_name" => "feat",
        "head_repository" => "acme/demo", "is_cross_repository" => false,
        "pr_state" => "OPEN", "branch" => "hive/review/pr-23",
        "generation" => 2, "previous_generation" => 1,
        "reviewed_oid" => oid_b, "candidate_oid" => oid_b,
        "previous_reviewed_oid" => oid_a, "retirement_label" => ret_label,
        "transaction_id" => tx_id, "head_transition_digest" => digest,
        "committed_at" => "2026-08-29T12:00:00Z"
      )
      store.seal_retirement!(label: ret_label)
      store.sync_current_history_root_digest!
      task = Hive::Task.new(folder)

      # Retain an old URL-only closed_unmerged observation from head A in the journal.
      stale_closed_a = [
        {
          "observed_at" => "2026-08-29T11:00:00Z",
          "payload" => {
            "activity_kind" => "pr_observed", "pr_url" => PR_URL, "pr_state" => "closed_unmerged"
          }
        }
      ]
      open_b_obs = {
        "pr_url" => PR_URL, "head_oid" => oid_b, "generation" => 2,
        "state" => "OPEN", "observed_at" => "2026-08-29T12:00:00Z"
      }

      # 1. Stale closed-A journal is ignored when reopened at open B; Review reaches worktree check.
      with_journal(stale_closed_a) do
        Hive::InternalPrCheckout.with_pr_observation(open_b_obs) do
          err = assert_raises(SystemExit) do
            capture_io { Hive::Stages::Review.run!(task, { "review" => {} }) }
          end
          assert_equal 1, err.status
        end
      end

      # 2. Currently merged or closed B still stops BEFORE every agent.
      [ [ "MERGED", :pull_request_merged ], [ "CLOSED", :pull_request_closed_unmerged ] ].each do |state, expected|
        with_journal([]) do
          with_replaced_singleton_method(Hive::Stages::Review::CiFix, :run!, ->(**) { flunk "agent must not run" }) do
            Hive::InternalPrCheckout.with_pr_observation(open_b_obs.merge("state" => state)) do
              result = nil
              capture_io { result = Hive::Stages::Review.run!(task, { "review" => {} }) }
              assert_equal({ commit: nil, status: expected }, result)
            end
          end
        end
      end

      # 3. A newer watcher observation bound to (pr_url, head_oid=B, generation=2)
      #    supersedes the earlier open observation on generation 2.
      newer_merged_b = stale_closed_a + [
        {
          "observed_at" => "2026-08-29T12:05:00Z",
          "payload" => {
            "activity_kind" => "merge_observed",
            "pr_url" => PR_URL,
            "head_oid" => oid_b,
            "generation" => 2,
            "pr_state" => "merged"
          }
        }
      ]
      with_journal(newer_merged_b) do
        with_replaced_singleton_method(Hive::Stages::Review::CiFix, :run!, ->(**) { flunk "agent must not run" }) do
          Hive::InternalPrCheckout.with_pr_observation(open_b_obs) do
            result = nil
            capture_io { result = Hive::Stages::Review.run!(task, { "review" => {} }) }
            assert_equal({ commit: nil, status: :pull_request_merged }, result)
          end
        end
      end

      # 4. Missing bound observation defers locally with remote_observation_required.
      File.write(File.join(folder, "pr.md"), <<~MD)
        ---
        source: ad-hoc
        pr_number: 23
        pr_url: #{PR_URL}
        head_oid: #{oid_b}
        base_ref_name: main
        head_ref_name: feat
        head_repository: acme/demo
        is_cross_repository: false
        ---
      MD
      store.write_current!(store.read_current.merge("pr_state" => nil))
      with_journal(stale_closed_a) do
        with_replaced_singleton_method(Hive::Stages::Review::CiFix, :run!, ->(**) { flunk "agent must not run" }) do
          err = assert_raises(Hive::Attempts::ReconciliationBusy) do
            capture_io { Hive::Stages::Review.run!(task, { "review" => {} }) }
          end
          assert_equal "remote_observation_required", err.reconciliation.reason
        end
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
