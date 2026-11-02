require "test_helper"
require "hive/stages/review"
require "hive/commands/review_grant"
require_relative "../../../support/review_grant_fixture"

class ReviewGrantRecoveryTest < Minitest::Test
  include HiveTestHelper
  include ReviewGrantFixture

  def grant(task)
    budget = Hive::ReviewBudget.new(task: task, project: task.project_name)
    capture_io do
      Hive::Commands::ReviewGrant.new(task.folder, project: task.project_name,
        passes: 1, reason: "Finish accepted fixes", evidence_token: budget.observe.evidence_token).call
    end
    budget
  end

  def test_sealed_completion_supplies_restart_receipt_and_head_before_markdown_sentinel
    with_review_grant_task do |task, _cfg|
      budget = grant(task)
      head = Hive::Stages::Review.git_head(task.worktree_path)
      budget.complete_fix!(snapshot: budget.observe, pass: 4, head: head)
      assert Hive::Stages::Review.completed_pass_receipt?(task.folder, 4)
      assert_equal head, Hive::Stages::Review.fix_success_head(task.folder, 4)
      refute File.exist?(Hive::Stages::Review.fix_success_path(task.folder, 4))
    end
  end

  def test_standalone_budget_reader_refuses_mutated_granted_evidence
    with_review_grant_task do |task, _cfg|
      grant(task)
      old_budget = Hive::Stages::Review.instance_variable_get(:@grant_budget)
      Hive::Stages::Review.instance_variable_set(:@grant_budget, nil)
      assert_equal "applied", Hive::Stages::Review.review_budget_snapshot_for(task.folder).state
      File.open(File.join(task.reviews_dir, "codex-04.md"), "a") { |file| file.puts "changed" }
      assert_raises(Hive::ReviewBudget::Refused) { Hive::Stages::Review.review_budget_snapshot_for(task.folder) }
    ensure
      Hive::Stages::Review.instance_variable_set(:@grant_budget, old_budget)
    end
  end

  def test_reviewer_budget_custody_refusal_propagates_instead_of_becoming_an_infra_failure
    adapter = Object.new
    adapter.define_singleton_method(:output_path) { "/tmp/reviewer.md" }
    adapter.define_singleton_method(:run!) do
      raise Hive::ReviewBudget::Refused.new("agent_modified_budget", "restored controller receipts")
    end
    with_replaced_singleton_method(Hive::Reviewers, :dispatch, ->(*) { adapter }) do
      error = assert_raises(Hive::ReviewBudget::Refused) do
        Hive::Stages::Review.run_reviewer_spec({}, nil, { "name" => "codex" }, nil)
      end
      assert_equal "agent_modified_budget", error.reason
    end
  end

  def test_reviewer_sources_remove_the_entire_extended_numeric_suffix
    with_tmp_dir do |folder|
      FileUtils.mkdir_p(File.join(folder, "reviews"))
      %w[codex-native-100.md claude-0100.md errors-100.md codex-99.md].each do |name|
        File.write(File.join(folder, "reviews", name), "# Review\n")
      end
      ctx = Hive::Stages::Review::Context.new(worktree_path: folder,
        task_folder: folder, default_branch: "main", pass: 100)
      assert_equal "claude,codex-native", Hive::Stages::Review.reviewer_sources_for(ctx)
    end
  end

  def test_phase_four_refuses_if_a_slot_disappears_before_launch
    with_review_grant_task do |task, cfg|
      budget = grant(task)
      original = Hive::ReviewBudget.instance_method(:next_slot)
      Hive::ReviewBudget.define_method(:next_slot) { |**| nil }
      capture_io do
        Hive::Lock.with_task_lock(task.folder, create: false) do
          assert_equal :review_error, Hive::Stages::Review.run!(task, cfg).fetch(:status)
        end
      end
      assert_empty budget.store.records.last
    ensure
      Hive::ReviewBudget.define_method(:next_slot, original) if original
    end
  end

  def test_stage_preserves_exact_restored_and_unsafe_budget_custody_diagnostics
    %w[agent_modified_budget unsafe_state].each do |reason|
      with_review_grant_task do |task, cfg|
        budget = grant(task)
        with_replaced_singleton_method(Hive::Stages::Review, :spawn_fix_agent, ->(*, **) {
          raise Hive::ReviewBudget::Refused.new(reason, "controller receipt custody refused")
        }) do
          capture_io do
            Hive::Lock.with_task_lock(task.folder, create: false) do
              assert_raises(Hive::ReviewBudget::Refused) { Hive::Stages::Review.run!(task, cfg) }
            end
          end
        end
        marker = Hive::Markers.current(task.state_file)
        assert_equal :review_error, marker.name
        assert_equal reason, marker.attrs["reason"]
        assert_equal "fix", marker.attrs["phase"]
        assert_empty budget.store.records.last
      end
    end
  end

  def test_granted_fix_cannot_rewrite_preserved_accepted_artifacts_or_spend_a_slot
    with_review_grant_task do |task, cfg|
      budget = grant(task)
      path = File.join(task.reviews_dir, "codex-04.md")
      before = File.binread(path)
      with_replaced_singleton_method(Hive::Stages::Review, :spawn_fix_agent, ->(*, agent_custody:, **) {
        agent_custody.call do
          File.write(path, "# Concealed accepted work\n")
          { status: :ok }
        end
      }) do
        capture_io do
          Hive::Lock.with_task_lock(task.folder, create: false) do
            assert_equal :review_error, Hive::Stages::Review.run!(task, cfg).fetch(:status)
          end
        end
      end
      assert_equal before, File.binread(path)
      assert_empty budget.store.records.last
      assert_equal "fix_tampered", Hive::Markers.current(task.state_file).attrs["reason"]
    end
  end

  def test_changed_binding_after_completion_stops_before_another_reviewer_launch
    with_review_grant_task do |task, cfg|
      budget = grant(task)
      original = Hive::Stages::Review.method(:write_fix_success)
      with_replaced_singleton_method(Hive::Stages::Review, :write_fix_success, ->(ctx, kind:) {
        original.call(ctx, kind: kind)
        File.open(File.join(task.reviews_dir, "codex-04.md"), "a") { |file| file.puts "Changed after completion" }
      }) do
        with_replaced_singleton_method(Hive::Stages::Review, :run_reviewers, ->(*) { flunk "changed budget evidence must stop before reviewers" }) do
          with_replaced_singleton_method(Hive::Stages::Review, :spawn_fix_agent, ->(*, agent_custody:, **) {
            agent_custody.call { { status: :ok } }
          }) do
            capture_io do
              Hive::Lock.with_task_lock(task.folder, create: false) do
                assert_equal :review_error, Hive::Stages::Review.run!(task, cfg).fetch(:status)
              end
            end
          end
        end
      end
      assert_equal 1, budget.store.records.last.length
    end
  end
end
