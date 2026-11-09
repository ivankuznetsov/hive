require "test_helper"
require "json_schemer"
require "hive/commands/review_grant"
require "hive/cli"
require_relative "../../support/review_grant_fixture"

class ReviewGrantCommandTest < Minitest::Test
  include HiveTestHelper
  include ReviewGrantFixture

  def test_operator_decision_is_durable_applied_and_identically_replayed
    with_review_grant_task do |task, _cfg|
      budget = Hive::ReviewBudget.new(task: task, project: task.project_name)
      snapshot = budget.observe
      assert_equal "eligible", snapshot.state, snapshot.remediation
      token = snapshot.evidence_token
      output, = capture_io do
        Hive::CLI.start([ "review-grant", task.folder, "--project", task.project_name,
          "--passes", "2", "--reason", "Finish verified accepted fixes", "--evidence-token", token, "--json" ])
      end
      applied = JSON.parse(output)
      assert_equal "applied", applied.fetch("state")
      assert_equal :none, Hive::Markers.current(task.state_file).name
      assert_equal 2, budget.observe.remaining
      before = Dir[File.join(task.folder, "reviews", "review-grant-*")].to_h { |path| [ path, File.binread(path) ] }
      output, = capture_io do
        Hive::Commands::ReviewGrant.new(task.folder, project: task.project_name,
          passes: "2", reason: "Finish verified accepted fixes  ", evidence_token: token, json: true).call
      end
      replay = JSON.parse(output)
      assert_equal "replayed", replay.fetch("state")
      assert_equal applied.fetch("decision_id"), replay.fetch("decision_id")
      assert_equal applied.fetch("decided_at"), replay.fetch("decided_at")
      assert_equal 2, budget.observe.remaining
      assert_equal before, before.keys.to_h { |path| [ path, File.binread(path) ] }
      assert_equal 1, File.readlines(budget.audit_path).size
      schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-review-grant"))))
      assert schema.valid?(applied), schema.validate(applied).to_a.inspect
      assert schema.valid?(replay)
      assert_raises(Hive::ReviewBudget::Refused) do
        capture_io do
          Hive::Commands::ReviewGrant.new(task.folder, project: task.project_name,
            passes: "3", reason: "Finish verified accepted fixes", evidence_token: token).call
        end
      end
      assert_equal 2, budget.observe.remaining
    end
  end

  def test_changed_evidence_and_scheduler_token_cannot_allocate
    with_review_grant_task do |task, _cfg|
      budget = Hive::ReviewBudget.new(task: task, project: task.project_name)
      token = budget.observe.evidence_token
      File.open(File.join(task.folder, "reviews", "codex-04.md"), "a") { |file| file.puts "Edited after observation" }
      before = File.binread(task.state_file)
      [ token, "b" * 64 ].each do |stale|
        assert_raises(Hive::ReviewBudget::Refused) do
          capture_io do
            Hive::Commands::ReviewGrant.new(task.folder, project: task.project_name,
              passes: "1", reason: "Finish verified fixes", evidence_token: stale).call
          end
        end
        assert_equal before, File.binread(task.state_file)
        refute budget.present?
        refute File.exist?(budget.audit_path)
      end
    end
  end

  def test_interrupted_receipt_application_reconciles_without_double_allocation
    with_review_grant_task do |task, _cfg|
      budget = Hive::ReviewBudget.new(task: task, project: task.project_name)
      token = budget.observe.evidence_token
      original = budget.method(:reconcile_audit!)
      interrupted = true
      budget.define_singleton_method(:reconcile_audit!) do |receipt|
        if interrupted
          interrupted = false
          raise IOError, "simulated loss after receipt fsync"
        end
        original.call(receipt)
      end
      with_replaced_singleton_method(Hive::ReviewBudget, :new, ->(**) { budget }) do
        assert_raises(Hive::InternalError) do
          capture_io do
            Hive::Commands::ReviewGrant.new(task.folder, project: task.project_name,
              passes: "1", reason: "Finish verified fixes", evidence_token: token).call
          end
        end
      end
      assert_equal :review_stale, Hive::Markers.current(task.state_file).name
      assert_equal 1, budget.store.grants.size
      refute File.exist?(budget.audit_path)
      output, = capture_io do
        Hive::Commands::ReviewGrant.new(task.folder, project: task.project_name,
          passes: "1", reason: "Finish verified fixes", evidence_token: token, json: true).call
      end
      assert_equal "replayed", JSON.parse(output).fetch("state")
      assert_equal :none, Hive::Markers.current(task.state_file).name
      assert_equal 1, budget.observe.remaining
      assert_equal 1, File.readlines(budget.audit_path).size
    end
  end

  def test_changed_marker_is_never_cleared_by_a_pending_replay
    with_review_grant_task do |task, _cfg|
      budget = Hive::ReviewBudget.new(task: task, project: task.project_name)
      snapshot = budget.observe
      budget.record_grant!(snapshot: snapshot, passes: "1", reason: "Finish verified fixes",
        caller: "uid:#{Process.uid}", source: "operator_cli")
      Hive::Markers.set(task.state_file, :review_ci_stale, attempts: 3, pass: 4)
      before = File.binread(task.state_file)
      assert_raises(Hive::ReviewBudget::Refused) do
        capture_io do
          Hive::Commands::ReviewGrant.new(task.folder, project: task.project_name,
            passes: "1", reason: "Finish verified fixes", evidence_token: snapshot.evidence_token).call
        end
      end
      assert_equal before, File.binread(task.state_file)
      assert_equal 1, budget.store.grants.size
    end
  end

  def test_daemon_reconciles_durable_intent_only_while_holding_task_lock
    with_review_grant_task do |task, _cfg|
      coordinator = Hive::Daemon::RecoveryCoordinator.new
      assert_raises(Hive::ReviewBudget::Refused) do
        coordinator.reconcile_review_grant!(task: task, project: task.project_name)
      end
      Hive::Lock.with_task_lock(task.folder, create: false) do
        assert_nil coordinator.reconcile_review_grant!(task: task, project: task.project_name)
        budget = Hive::ReviewBudget.new(task: task, project: task.project_name)
        budget.record_grant!(snapshot: budget.observe, passes: 3, reason: "Finish verified fixes",
          caller: "uid:#{Process.uid}", source: "operator_cli")
        result = coordinator.reconcile_review_grant!(task: task, project: task.project_name)
        assert_equal "applied", result.state
        assert_equal 3, result.remaining
        assert_equal :none, Hive::Markers.current(task.state_file).name
        assert_equal "applied", coordinator.reconcile_review_grant!(task: task, project: task.project_name).state
      end
    end
  end

  def test_invalid_decision_inputs_never_reach_recovery
    calls = 0
    coordinator = Object.new
    coordinator.define_singleton_method(:grant_review!) { |**| calls += 1 }
    invalid = [ nil, "", "0", "-1", "4", "1.0", "1a", " 1", "1 ", 1.5 ]
    invalid.each do |passes|
      error = assert_raises(Hive::UsageError) do
        capture_io do
          Hive::Commands::ReviewGrant.new("target", project: "demo", passes: passes,
            reason: "Finish verified fixes", evidence_token: "a" * 64,
            coordinator: coordinator, json: true).call
        end
      end
      assert_match(/passes/, error.message)
    end
    [ nil, "", " \t ", "line\nbreak", "escape\e", "x" * 1025, "\xff".b ].each do |reason|
      assert_raises(Hive::UsageError) do
        capture_io do
          Hive::Commands::ReviewGrant.new("target", project: "demo", passes: "2",
            reason: reason, evidence_token: "a" * 64, coordinator: coordinator).call
        end
      end
    end
    assert_equal 0, calls
  end

  def test_missing_project_or_evidence_is_a_usage_error
    [ [ nil, "a" * 64 ], [ "demo", nil ], [ "demo", "" ], [ "demo", "not-a-token" ] ].each do |project, token|
      assert_raises(Hive::UsageError) do
        capture_io do
          Hive::Commands::ReviewGrant.new("target", project: project, passes: "1",
            reason: "Finish verified fixes", evidence_token: token).call
        end
      end
    end
  end

  def test_usage_contract_has_the_published_schema
    contract = Hive::CliUsageContracts.contract(%w[review-grant --json])
    assert_equal "hive-review-grant", contract.fetch(:schema)
    assert_equal "usage", contract.fetch(:error_kind)
    doc = JSON.parse(File.read(Hive::Schemas.schema_path("hive-review-grant")))
    assert_equal Hive::Schemas::ReviewGrantErrorKind::ALL.sort,
      doc.dig("$defs", "ErrorPayload", "properties", "error_kind", "enum").sort
    error = Hive::Schemas::ErrorEnvelope.build(schema: "hive-review-grant",
      error: Hive::UsageError.new("missing decision"), error_kind: "usage")
    assert JSONSchemer.schema(doc).valid?(error)
  end

  def test_refusal_envelopes_preserve_machine_reason_and_operator_remediation
    with_review_grant_task do |task, _cfg|
      failures = {
        "decision_conflict" => "decision_conflict", "unsafe_state" => "unsafe_state",
        "invalid_passes" => "usage", "invalid_reason" => "usage",
        "head_changed" => "stale_evidence", "evidence_changed" => "stale_evidence",
        "stale_evidence" => "stale_evidence", "invalid_task_history" => "evidence_unavailable"
      }
      failures.each do |reason, kind|
        error = Hive::ReviewBudget::Refused.new(reason, "Grant refused: #{reason}",
          remediation: "Refresh this task's operational observation.")
        payload = command_failure(task, error)
        assert_equal kind, payload.fetch("error_kind")
        assert_equal reason, payload.fetch("refusal_reason")
        assert_equal error.remediation, payload.fetch("remediation")
      end
    end
  end

  def test_command_boundary_errors_keep_exit_codes_and_schema_valid_envelopes
    with_review_grant_task do |task, _cfg|
      failures = [
        [ Hive::UsageError.new("Required option absent"), "usage" ],
        [ Hive::AmbiguousSlug.new("Two matching tasks", slug: "grant", candidates: [ "grant-a", "grant-b" ]), "ambiguous_target" ],
        [ Hive::InvalidTaskPath.new("Task moved"), "invalid_task_path" ],
        [ Hive::ConcurrentRunError.new("Live task owner", holder: { "pid" => Process.pid }, lock_path: "task-lease"), "concurrent_run" ],
        [ Hive::ConfigError.new("Invalid project configuration"), "config" ],
        [ Hive::InternalError.new("Receipt I/O failed"), "internal" ],
        [ Hive::Error.new("Unclassified operator failure"), "error" ],
        [ Hive::AgentSupport::OperatorAuthority::Denied.new, "agent_denied" ],
        [ Hive::AgentSupport::OperatorAuthority::AuthorityUnavailable.new, "source_unverified" ]
      ]
      failures.each do |error, kind|
        payload = command_failure(task, error)
        assert_equal kind, payload.fetch("error_kind")
        assert_equal error.exit_code, payload.fetch("exit_code")
        assert_equal kind, payload.fetch("refusal_reason")
      end
    end
  end

  def test_text_success_reports_decision_without_rendering_audit_reason
    with_review_grant_task do |task, _cfg|
      token = Hive::ReviewBudget.new(task: task, project: task.project_name).observe.evidence_token
      payload = nil
      output, = capture_io do
        payload = Hive::Commands::ReviewGrant.new(task.folder, project: task.project_name,
          passes: "1", reason: "Keep reason in audit", evidence_token: token).call
      end
      assert_match(/#{Regexp.escape(task.slug)}: review grant #{payload.fetch('decision_id')} applied;/, output)
      assert_includes output, "Verification and existing recovery holds still apply."
      refute_includes output, "Keep reason in audit"
    end
  end

  def test_unserializable_failure_is_raised_without_emitting_a_partial_envelope
    with_review_grant_task do |task, _cfg|
      error = Hive::ConcurrentRunError.new("Live owner", holder: { "bad" => "\xff".b })
      coordinator = Object.new
      coordinator.define_singleton_method(:grant_review!) { |**| raise error }
      output, = capture_io do
        assert_raises(JSON::GeneratorError) do
          Hive::Commands::ReviewGrant.new(task.folder, project: task.project_name,
            passes: 1, reason: "Finish accepted fixes", evidence_token: "a" * 64,
            coordinator: coordinator, json: true).call
        end
      end
      assert_empty output
    end
  end

  private

  def command_failure(task, error)
    coordinator = Object.new
    coordinator.define_singleton_method(:grant_review!) { |**| raise error }
    output, = capture_io do
      raised = assert_raises(error.class) do
        Hive::Commands::ReviewGrant.new(task.folder, project: task.project_name,
          passes: 1, reason: "Finish accepted fixes", evidence_token: "a" * 64,
          coordinator: coordinator, json: true).call
      end
      assert_same error, raised
    end
    payload = JSON.parse(output)
    schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-review-grant"))))
    assert schema.valid?(payload), schema.validate(payload).to_a.inspect
    refute payload.fetch("ok")
    assert_equal error.class.name.split("::").last, payload.fetch("error_class")
    payload
  end
end
