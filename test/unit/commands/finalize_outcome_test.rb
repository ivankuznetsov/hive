require "test_helper"
require "hive/commands/finalize_outcome"
require "hive/finalization/reconciler"
require "hive/task_journal/envelope"
require "hive/task_meta"

class CommandsFinalizeOutcomeTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 17, 19, 0, 0)

  def test_approve_is_tty_only_and_requires_reason_and_typed_outcome
    with_context do |ctx|
      input = StringIO.new
      error = assert_raises(Hive::InvalidTaskPath) do
        command(ctx, input: input).call
      end
      assert_includes error.message, "local-TTY only"
      assert_equal 1, journal(ctx).size

      assert_raises(Hive::InvalidTaskPath) do
        command(ctx, reason: "", input: tty_input("")).call
      end
      assert_raises(Hive::InvalidTaskPath) do
        command(ctx, outcome: nil, input: tty_input("")).call
      end
    end
  end

  def test_exact_confirmation_appends_audited_approval_then_reconciles_once
    with_context do |ctx|
      confirmation = "approve durable-task 3 abandonment\n"
      output = StringIO.new

      result = command(ctx, input: tty_input(confirmation), output: output).call
      record = journal(ctx).last

      assert_equal :approved, result.status
      assert_equal "approved_no_pr", result.state
      assert_equal "no_pr_approved", record.fetch("event_type")
      assert_equal "operator", record.dig("producer", "kind")
      assert_equal "local_tty", record.dig("producer", "channel")
      assert_equal 1001, record.dig("producer", "uid")
      assert_equal "alice", record.dig("producer", "login")
      assert_equal "retiring duplicate work", record.dig("payload", "operator_reason")
      assert_equal "CLOSED", record.dig("evidence", 0, "value", "current_pr", "state")
      assert_includes output.string, "consequence: archive reconciliation may remove"
      assert_equal "terminal", ctx.fetch(:store).read(ctx.dig(:job, "job_id")).fetch("state")

      retry_result = command(ctx, input: tty_input(""), output: output).call
      assert_equal :already_recorded, retry_result.status
      assert_equal 2, journal(ctx).size

      reconciler = Hive::Finalization::Reconciler.new(task_folder: ctx.fetch(:task_folder), clock: -> { NOW + 1 })
      assert_equal :archive_ready, reconciler.reconcile.status
      assert_equal :already_ready, reconciler.reconcile.status
      assert_equal 1, journal(ctx).count { |event| event["event_type"] == "archive_ready" }
    end
  end

  def test_wrong_confirmation_and_eof_leave_journal_unchanged
    with_context do |ctx|
      [ "yes\n", "" ].each do |answer|
        error = assert_raises(Hive::InvalidTaskPath) do
          command(ctx, input: tty_input(answer)).call
        end
        assert_includes error.message, "did not match exactly"
        assert_equal 1, journal(ctx).size
      end
    end
  end

  def test_rearm_is_append_only_and_invalidates_unconsumed_approval
    with_context do |ctx|
      command(ctx, input: tty_input("approve durable-task 3 abandonment\n")).call

      result = command(
        ctx, action: "rearm", outcome: nil, reason: "new handoff is valid",
        input: tty_input("rearm durable-task 3\n")
      ).call
      records = journal(ctx)

      assert_equal :rearmed, result.status
      assert_equal "babysitter_active", result.state
      assert_equal %w[finalized no_pr_approved finalization_rearmed], records.map { |event| event["event_type"] }
      assert_equal records[1].fetch("event_id"), records[2].dig("payload", "approval_event_id")
      assert_equal "active", ctx.fetch(:store).read(ctx.dig(:job, "job_id")).fetch("state")
      assert_equal :not_eligible,
                   Hive::Finalization::Reconciler.new(task_folder: ctx.fetch(:task_folder)).reconcile.status
    end
  end

  def test_rearmed_outcome_can_be_approved_again_as_new_append_only_evidence
    with_context do |ctx|
      first = command(ctx, input: tty_input("approve durable-task 3 abandonment\n")).call
      command(
        ctx, action: "rearm", outcome: nil, reason: "new handoff is valid",
        input: tty_input("rearm durable-task 3\n")
      ).call

      second = command(ctx, input: tty_input("approve durable-task 3 abandonment\n")).call

      refute_equal first.event_id, second.event_id
      assert_equal %w[finalized no_pr_approved finalization_rearmed no_pr_approved],
                   journal(ctx).map { |event| event["event_type"] }
    end
  end

  def test_rearm_after_archive_ready_is_rejected
    with_context do |ctx|
      command(ctx, input: tty_input("approve durable-task 3 abandonment\n")).call
      Hive::Finalization::Reconciler.new(task_folder: ctx.fetch(:task_folder), clock: -> { NOW + 1 }).reconcile

      error = assert_raises(Hive::Finalization::OutcomeValidator::NotEligible) do
        command(
          ctx, action: "rearm", outcome: nil, reason: "too late",
          input: tty_input("rearm durable-task 3\n")
        ).call
      end
      assert_includes error.message, "unconsumed"
      assert_equal 3, journal(ctx).size
    end
  end

  def test_argument_and_tty_errors_fail_before_resolution
    with_context do |ctx|
      assert_raises(Hive::InvalidTaskPath) do
        command(ctx, action: "erase", input: tty_input("")).call
      end
      assert_raises(Hive::InvalidTaskPath) do
        command(ctx, action: "rearm", outcome: "abandonment", evidence: "proof",
                input: tty_input("")).call
      end

      broken_tty = StringIO.new
      broken_tty.define_singleton_method(:tty?) { raise IOError, "closed" }
      assert_raises(Hive::InvalidTaskPath) do
        command(ctx, input: broken_tty).call
      end
    end
  end

  def test_missing_handoff_and_superseded_current_job_fail_closed
    with_context do |ctx|
      File.write(File.join(ctx.fetch(:task_folder), "events.jsonl"), "")
      assert_raises(Hive::Finalization::OutcomeValidator::NotEligible) do
        command(ctx, input: tty_input("")).call
      end
    end

    with_context do |ctx|
      old = ctx.fetch(:job)
      replacement = ctx.fetch(:store).reserve_replacement!(
        old_job_id: old.fetch("job_id"), remote_state: "CLOSED", remote_observed_at: NOW.iso8601,
        project: old.dig("identity", "project"), task_id: 42, task_slug: "durable-task",
        task_generation: 3, repository: "github.com/acme/demo", pr_number: 13,
        pr_url: "https://github.com/acme/demo/pull/13", branch: "feature/durable",
        head_sha: "b" * 40, head_generation: 1, finalize_attempt_id: "attempt-2",
        task_folder: ctx.fetch(:task_folder), now: NOW
      )
      refute_equal old.fetch("job_id"), replacement.fetch("job_id")
      assert_raises(Hive::Finalization::OutcomeValidator::NotEligible) do
        command(ctx, input: tty_input("")).call
      end
    end
  end

  def test_rearm_retry_repairs_registry_without_a_duplicate_event
    with_context do |ctx|
      command(ctx, input: tty_input("approve durable-task 3 abandonment\n")).call
      first = command(
        ctx, action: "rearm", outcome: nil, reason: "resume",
        input: tty_input("rearm durable-task 3\n")
      ).call
      replay = command(
        ctx, action: "rearm", outcome: nil, reason: "resume",
        input: tty_input("")
      ).call

      assert_equal :rearmed, first.status
      assert_equal :already_recorded, replay.status
      assert_equal 1, journal(ctx).count { |event| event["event_type"] == "finalization_rearmed" }
    end
  end

  def test_rearm_requires_a_retired_or_active_operational_job
    with_context do |ctx|
      command(ctx, input: tty_input("approve durable-task 3 abandonment\n")).call
      ctx.fetch(:store).send(:mutate, ctx.dig(:job, "job_id")) do |record|
        record["state"] = "superseded"
        record
      end

      assert_raises(Hive::Finalization::OutcomeValidator::NotEligible) do
        command(
          ctx, action: "rearm", outcome: nil, reason: "resume",
          input: tty_input("rearm durable-task 3\n")
        ).call
      end
    end
  end

  def test_local_actor_resolution_uses_os_identity_and_fails_closed
    command_object = Hive::Commands::FinalizeOutcome.new(
      "task", "approve", outcome: "abandonment", reason: "reason"
    )
    assert_kind_of Time, command_object.instance_variable_get(:@clock).call
    actor = command_object.send(:local_actor)
    assert_equal Process.euid, actor.fetch("uid")
    refute_empty actor.fetch("login")

    with_replaced_singleton_method(Etc, :getlogin, -> { "" }) do
      empty_user = Struct.new(:name).new("")
      with_replaced_singleton_method(Etc, :getpwuid, ->(_uid) { empty_user }) do
        assert_raises(Hive::Finalization::OutcomeValidator::NotEligible) do
          command_object.send(:local_actor)
        end
      end
      with_replaced_singleton_method(Etc, :getpwuid, ->(_uid) { raise ArgumentError, "missing uid" }) do
        assert_raises(Hive::Finalization::OutcomeValidator::NotEligible) do
          command_object.send(:local_actor)
        end
      end
    end
  end

  private

  def command(ctx, action: "approve", outcome: "abandonment", reason: "retiring duplicate work",
              evidence: nil, input:, output: StringIO.new)
    Hive::Commands::FinalizeOutcome.new(
      ctx.fetch(:task_folder), action, outcome: outcome, reason: reason, evidence: evidence,
      input: input, output: output, clock: -> { NOW }, snapshot_loader: ->(_url, _cfg) { ctx.fetch(:snapshot) },
      actor_resolver: -> { { "uid" => 1001, "login" => "alice" } }
    )
  end

  def tty_input(content)
    input = StringIO.new(content)
    input.define_singleton_method(:tty?) { true }
    input
  end

  def journal(ctx)
    Hive::TaskProjection.read_journal(File.join(ctx.fetch(:task_folder), "events.jsonl"))
  end

  def with_context
    with_tmp_dir do |project|
      task_folder = File.join(project, ".hive-state", "stages", "8-finalize", "durable-task")
      FileUtils.mkdir_p(task_folder)
      File.write(File.join(project, ".hive-state", "config.yml"), { "default_workflow" => "coding" }.to_yaml)
      Hive::TaskMeta.write(task_folder, id: 42, slug: "durable-task", display_name: "Durable task")
      File.write(File.join(task_folder, "worktree.yml"), { "path" => project, "branch" => "feature/durable" }.to_yaml)

      store = Hive::Babysitter::JobStore.new(project_root: project, clock: -> { NOW })
      job = store.reserve!(
        project: File.basename(project), task_id: 42, task_slug: "durable-task", task_generation: 3,
        repository: "github.com/acme/demo", pr_number: 12,
        pr_url: "https://github.com/acme/demo/pull/12", branch: "feature/durable",
        head_sha: "a" * 40, head_generation: 1, finalize_attempt_id: "attempt-1",
        task_folder: task_folder, now: NOW
      )
      event = finalized_event(job)
      File.write(File.join(task_folder, "events.jsonl"), "#{JSON.generate(event)}\n")
      store.activate!(job.fetch("job_id"), handoff_event_id: event.fetch("event_id"),
                      finalize_attempt_id: "attempt-1", now: NOW)
      snapshot = Hive::Gh::PrSnapshot.new(
        repository: "github.com/acme/demo", number: 12,
        url: "https://github.com/acme/demo/pull/12", state: "CLOSED", head_sha: "a" * 40,
        head_branch: "feature/durable", base_branch: "main", merged_at: nil,
        observed_at: NOW.iso8601(6), mergeable: nil, merge_state_status: nil,
        review_decision: nil, status_check_rollup: []
      )
      yield task_folder: task_folder, store: store, job: job, snapshot: snapshot
    end
  end

  def finalized_event(job)
    identity = job.fetch("identity")
    Hive::TaskJournal::Envelope.authoritative({
      event_id: "finalized-1", event_type: "finalized", occurred_at: NOW.iso8601(6),
      observed_at: NOW.iso8601(6), task: { "id" => "42", "slug" => "durable-task" },
      workflow: "coding", stage: "8-finalize", attempt_id: "attempt-1", task_generation: 3,
      ownership_generation: "owner-1", reason: "handoff", evidence: [],
      provenance: { "source" => "test" },
      producer: { "kind" => "finalize_attempt", "attempt_id" => "attempt-1" },
      payload: {
        "job_id" => job.fetch("job_id"), "repository" => identity.fetch("repository"),
        "pr_number" => identity.fetch("pr_number"), "pr_url" => job.fetch("pr_url"),
        "head_sha" => job.fetch("head_sha"), "head_generation" => job.fetch("head_generation"),
        "finalize_attempt_id" => "attempt-1"
      }
    })
  end
end
