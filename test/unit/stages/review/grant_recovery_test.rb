require "test_helper"
require "hive/stages/review"
require "hive/commands/review_grant"
require_relative "../../../support/review_grant_fixture"

class ReviewGrantRecoveryTest < Minitest::Test
  include HiveTestHelper
  include ReviewGrantFixture

  def grant(task, passes: 1)
    budget = Hive::ReviewBudget.new(task: task, project: task.project_name)
    capture_io do
      Hive::Commands::ReviewGrant.new(task.folder, project: task.project_name,
        passes: passes, reason: "Finish accepted fixes", evidence_token: budget.observe.evidence_token).call
    end
    budget
  end

  def test_sealed_completion_spends_slot_but_requires_guardrail_disposition_before_advancing
    with_review_grant_task do |task, _cfg|
      budget = grant(task)
      head = Hive::Stages::Review.git_head(task.worktree_path)
      budget.complete_fix!(snapshot: budget.observe, pass: 4, head: head)
      refute Hive::Stages::Review.completed_pass_receipt?(task.folder, 4)
      assert_equal :guardrail_incomplete, Hive::Stages::Review.pass_completion_status(task.folder, 4)
      assert_equal 4, Hive::Stages::Review.next_pass_for(task, Hive::Markers.current(task.state_file))
      assert_equal [ 1, 0 ], [ budget.observe.spent, budget.observe.remaining ]
      assert_equal head, Hive::Stages::Review.fix_success_head(task.folder, 4)
      path = Hive::Stages::Review.fix_success_path(task.folder, 4)
      refute File.exist?(path)
      [ [ "a" * 40, "fixed" ], [ head, "clean" ] ].each do |bound_head, kind|
        File.write(path, "<!-- HIVE: head=#{bound_head} kind=#{kind} -->\n")
        assert_equal :guardrail_incomplete, Hive::Stages::Review.pass_completion_status(task.folder, 4)
      end
      File.write(path, "<!-- HIVE: head=#{head} kind=fixed -->\n")
      assert Hive::Stages::Review.completed_pass_receipt?(task.folder, 4)
      assert_equal 5, Hive::Stages::Review.next_pass_for(task, Hive::Markers.current(task.state_file))
    end
  end

  def test_restart_recovers_guardrail_after_receipt_or_report_before_advancing
    [ :check_fix_guardrail, :write_fix_guardrail_findings ].each do |boundary|
      with_review_grant_task do |task, cfg|
        budget = grant(task)
        base = Hive::Stages::Review.git_head(task.worktree_path)
        git_command = method(:run!)
        fix = lambda do |*, agent_custody:, **|
          agent_custody.call do
            path = File.join(task.worktree_path, ".github", "workflows", "check.yml")
            FileUtils.mkdir_p(File.dirname(path))
            File.write(path, "name: Check\n")
            git_command.call("git", "-C", task.worktree_path, "add", ".github/workflows/check.yml")
            git_command.call("git", "-C", task.worktree_path, "commit", "--quiet", "-m", "Update workflow")
            { status: :ok }
          end
        end
        original = Hive::Stages::Review.method(boundary)
        crash = lambda do |*args, **kwargs|
          original.call(*args, **kwargs) if boundary == :write_fix_guardrail_findings
          raise SystemExit, "simulated crash before durable guardrail disposition"
        end
        with_replaced_singleton_method(Hive::Stages::Review, :spawn_fix_agent, fix) do
          with_replaced_singleton_method(Hive::Stages::Review, boundary, crash) do
            capture_io do
              Hive::Lock.with_task_lock(task.folder, create: false) do
                assert_raises(SystemExit) { Hive::Stages::Review.run!(task, cfg) }
              end
            end
          end
        end
        completion = budget.observe.completions.fetch(0)
        assert_equal base, completion.fetch("input_head")
        assert_equal :guardrail_incomplete, Hive::Stages::Review.pass_completion_status(task.folder, 4)
        refute Hive::Stages::Review.completed_pass_receipt?(task.folder, 4)
        refute File.exist?(Hive::Stages::Review.fix_success_path(task.folder, 4))

        # Recovery must scan the sealed diff before even the entry CI gate.
        with_replaced_singleton_method(Hive::Stages::Review, :run_ci_gates, ->(*, **) { flunk "CI before guardrail admission" }) do
          with_replaced_singleton_method(Hive::Stages::Review, :run_reviewers, ->(*, **) { flunk "review before guardrail admission" }) do
            with_replaced_singleton_method(Hive::Stages::Review, :spawn_fix_agent, ->(*, **) { flunk "spent slot must not launch another fix" }) do
              2.times do
                capture_io do
                  Hive::Lock.with_task_lock(task.folder, create: false) do
                    assert_equal :review_waiting, Hive::Stages::Review.run!(task, cfg).fetch(:status)
                  end
                end
              end
            end
          end
        end
        marker = Hive::Markers.current(task.state_file)
        assert_equal "fix_guardrail", marker.attrs.fetch("reason")
        assert_equal completion.fetch("head"), marker.attrs.fetch("head")
        assert_equal "4", marker.attrs.fetch("pass")
        assert_equal [ 1, 0 ], [ budget.observe.spent, budget.observe.remaining ]
        report = File.join(task.reviews_dir, "fix-guardrail-04.md")
        assert_includes File.read(report), ".github/workflows/check.yml"
        assert_includes File.read(report), "- [ ]"

        File.write(report, File.read(report).gsub("- [ ]", "- [x]"))
        reviewed_passes = []
        review = lambda do |_cfg, ctx, _task, **|
          # Only the fresh verify pass may be reviewed after approval.
          reviewed_passes << ctx.pass
          File.write(File.join(task.reviews_dir, "codex-05.md"), "No findings.\n")
          :ok
        end
        triage = lambda do |cfg:, ctx:|
          path = File.join(ctx.task_folder, "reviews", "escalations-#{format('%02d', ctx.pass)}.md")
          File.write(path, "# Escalations\n")
          Hive::Stages::Review::Triage::Result.new(status: :ok, escalations_path: path,
            error_message: nil, tampered_files: [], limit_text: nil)
        end
        with_replaced_singleton_method(Hive::Stages::Review, :run_reviewers, review) do
          with_replaced_singleton_method(Hive::Stages::Review::Triage, :run!, triage) do
            with_replaced_singleton_method(Hive::Stages::Review, :spawn_fix_agent, ->(*, **) { flunk "approval must preserve spent slot" }) do
              capture_io do
                Hive::Lock.with_task_lock(task.folder, create: false) do
                  assert_equal :review_complete, Hive::Stages::Review.run!(task, cfg).fetch(:status), File.read(task.state_file)
                end
              end
            end
          end
        end
        assert_equal [ 5 ], reviewed_passes
        assert_equal [ completion ], budget.observe.completions
      end
    end
  end

  def test_restart_after_clean_guardrail_before_sentinel_rechecks_then_verifies_without_fixing
    with_review_grant_task do |task, cfg|
      budget = grant(task)
      with_replaced_singleton_method(Hive::Stages::Review, :spawn_fix_agent, ->(*, agent_custody:, **) {
        agent_custody.call { { status: :ok } }
      }) do
        with_replaced_singleton_method(Hive::Stages::Review, :write_fix_success, ->(*, **) { raise SystemExit, "before sentinel" }) do
          capture_io do
            Hive::Lock.with_task_lock(task.folder, create: false) do
              assert_raises(SystemExit) { Hive::Stages::Review.run!(task, cfg) }
            end
          end
        end
      end
      completion = budget.observe.completions.fetch(0)
      calls = []
      original = Hive::Stages::Review::FixGuardrail.method(:run!)
      with_replaced_singleton_method(Hive::Stages::Review::FixGuardrail, :run!, ->(**args) {
        calls << args.values_at(:base_sha, :head_sha)
        original.call(**args)
      }) do
        with_replaced_singleton_method(Hive::Stages::Review, :spawn_fix_agent, ->(*, **) { flunk "spent slot must not launch another fix" }) do
          capture_io do
            Hive::Lock.with_task_lock(task.folder, create: false) do
              assert_equal :review_complete, Hive::Stages::Review.run!(task, cfg).fetch(:status), File.read(task.state_file)
            end
          end
        end
      end
      assert_equal [ [ completion.fetch("input_head"), completion.fetch("head") ] ], calls
      assert File.exist?(Hive::Stages::Review.fix_success_path(task.folder, 4))
      assert_equal [ completion ], budget.observe.completions
    end
  end

  def test_pending_guardrail_refuses_changed_head_or_dirty_worktree_before_ci
    [ :head, :dirty ].each do |change|
      with_review_grant_task do |task, cfg|
        budget = grant(task)
        head = Hive::Stages::Review.git_head(task.worktree_path)
        completion = budget.complete_fix!(snapshot: budget.observe, pass: 4, head: head)
        if change == :head
          run!("git", "-C", task.worktree_path, "commit", "--quiet", "--allow-empty", "-m", "Change after sealed completion")
        else
          File.write(File.join(task.worktree_path, "unreviewed.txt"), "Unreviewed edits\n")
        end

        stderr = nil
        with_replaced_singleton_method(Hive::Stages::Review, :run_ci_gates, ->(*, **) { flunk "changed completion must stop before CI" }) do
          _stdout, stderr = capture_io do
            Hive::Lock.with_task_lock(task.folder, create: false) do
              assert_equal :review_error, Hive::Stages::Review.run!(task, cfg).fetch(:status)
            end
          end
        end
        assert_includes stderr, "review grant refused"
        assert_includes stderr, "awaiting guardrail admission has changed HEAD or dirty worktree edits"
        assert_equal [ completion ], budget.store.records.last
        refute File.exist?(Hive::Stages::Review.fix_success_path(task.folder, 4))
      end
    end
  end

  def test_standalone_escalation_reader_finds_later_answers_with_an_unused_slot
    with_review_grant_task do |task, _cfg|
      path = File.join(task.reviews_dir, "escalations-04.md")
      original = "### Q1. Apply the additional fix?\n### A1.\n\n"
      File.write(path, original)
      Hive::Markers.set(task.state_file, :review_stale,
        reason: "final_fix_unverified", pass: 4, accepted: 1, escalations: 1)
      budget = grant(task, passes: 2)
      head = Hive::Stages::Review.git_head(task.worktree_path)
      completion = budget.complete_fix!(snapshot: budget.observe, pass: 4, head: head)
      File.write(path, original.sub("### A1.\n", "### A1.\nYes, apply it.\n"))

      old_budget = Hive::Stages::Review.instance_variable_get(:@grant_budget)
      Hive::Stages::Review.instance_variable_set(:@grant_budget, nil)
      assert_equal [ 0 ], Hive::Stages::Review.pending_granted_escalation_answers(task.folder, completion)
      assert_equal [ completion ], budget.store.records.last
      assert_equal 1, budget.observe.remaining
    ensure
      Hive::Stages::Review.instance_variable_set(:@grant_budget, old_budget)
    end
  end

  def test_noop_retry_of_failed_guarded_commit_preserves_original_diff_and_completion_input
    [ false, true ].each do |restart|
      with_review_grant_task do |task, cfg|
        budget = grant(task)
        base = Hive::Stages::Review.git_head(task.worktree_path)
        git_command = method(:run!)
        fix = lambda do |*, agent_custody:, **|
          agent_custody.call do
            path = File.join(task.worktree_path, ".github", "workflows", "check.yml")
            FileUtils.mkdir_p(File.dirname(path))
            File.write(path, "name: Check\n")
            git_command.call("git", "-C", task.worktree_path, "add", ".github/workflows/check.yml")
            git_command.call("git", "-C", task.worktree_path, "commit", "--quiet", "-m", "Update workflow")
            { status: :error, error_message: "provider error after commit" }
          end
        end
        with_replaced_singleton_method(Hive::Stages::Review, :spawn_fix_agent, fix) do
          capture_io do
            Hive::Lock.with_task_lock(task.folder, create: false) do
              assert_equal :review_error, Hive::Stages::Review.run!(task, cfg).fetch(:status)
            end
          end
        end
        partial_head = Hive::Stages::Review.git_head(task.worktree_path)
        refute_equal base, partial_head
        assert_empty budget.observe.completions
        proof = Hive::Markers.current(task.state_file).attrs.slice("grant_decision", "grant_slot",
          "input_head", "head", "input_artifacts_digest", "pass", "phase")
        assert_equal base, proof.fetch("input_head")
        # Retain the same proof that recovery journals before clearing the park.
        event = Hive::TaskJournal::Envelope.authoritative({
          event_type: "activity_recorded", task: { "id" => task.id, "slug" => task.slug },
          workflow: "coding", stage: "6-review", attempt_id: "retry-1", task_generation: 0,
          reason: "preserved granted fix recovery evidence",
          provenance: { "source" => "recovery_service" },
          payload: { "activity_kind" => "recovery_recorded", "operation_id" => "retry-1", "review_grant_resume" => proof }
        })
        File.open(File.join(task.folder, "task-journal.jsonl"), "a") { |file| file.puts(JSON.generate(event)) }
        Hive::Markers.clear_current(task.state_file, expected_name: :review_error)

        with_replaced_singleton_method(Hive::Stages::Review, :spawn_fix_agent, ->(*, agent_custody:, **) {
          agent_custody.call { { status: :ok } }
        }) do
          capture_io do
            Hive::Lock.with_task_lock(task.folder, create: false) do
              if restart
                with_replaced_singleton_method(Hive::Stages::Review, :check_fix_guardrail, ->(*, **) { raise SystemExit, "before guardrail" }) do
                  assert_raises(SystemExit) { Hive::Stages::Review.run!(task, cfg) }
                end
              else
                assert_equal :review_waiting, Hive::Stages::Review.run!(task, cfg).fetch(:status), File.read(task.state_file)
              end
            end
          end
        end
        completion = budget.observe.completions.fetch(0)
        assert_equal base, completion.fetch("input_head")
        assert_equal partial_head, completion.fetch("head")
        if restart
          with_replaced_singleton_method(Hive::Stages::Review, :spawn_fix_agent, ->(*, **) { flunk "spent slot must not launch another fix" }) do
            capture_io do
              Hive::Lock.with_task_lock(task.folder, create: false) do
                assert_equal :review_waiting, Hive::Stages::Review.run!(task, cfg).fetch(:status)
              end
            end
          end
        end
        assert_equal "fix_guardrail", Hive::Markers.current(task.state_file).attrs.fetch("reason")
        assert_includes File.read(File.join(task.reviews_dir, "fix-guardrail-04.md")), ".github/workflows/check.yml"
        refute Hive::Stages::Review.completed_pass_receipt?(task.folder, 4)
        assert_equal [ 1, 0 ], [ budget.observe.spent, budget.observe.remaining ]
      end
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
