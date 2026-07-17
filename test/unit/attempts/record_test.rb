require "test_helper"
require "hive/attempts/record"

class AttemptsRecordTest < Minitest::Test
  NOW = Time.utc(2026, 7, 16, 12, 0, 0)

  def test_launching_record_exposes_unclaimed_deadline_and_immutable_identity
    record = Hive::Attempts::Record.launching(**identity, now: NOW, launch_timeout_sec: 30)

    assert_equal "launching", record.state
    assert record.live?
    refute record.claimed?
    assert_equal NOW + 30, record.active_deadline
    assert_equal 0, record.lease_version
    assert_equal "attempt-1", record.attempt_id
    assert_equal "generation-1", record.task_generation
  end

  def test_validate_rejects_unknown_state_and_terminal_fields_on_live_record
    invalid = Hive::Attempts::Record.launching(**identity, now: NOW, launch_timeout_sec: 30).to_h
    invalid["state"] = "maybe"

    error = assert_raises(Hive::Attempts::InvalidRecord) do
      Hive::Attempts::Record.new(invalid)
    end
    assert_includes error.message, "state"

    invalid = Hive::Attempts::Record.launching(**identity, now: NOW, launch_timeout_sec: 30).to_h
    invalid["outcome"] = "succeeded"
    assert_raises(Hive::Attempts::InvalidRecord) { Hive::Attempts::Record.new(invalid) }
  end

  def test_terminal_receipt_rejects_identity_time_and_integrity_errors
    valid = receipt
    assert Hive::Attempts::Record.validate_receipt!(valid, attempt_id: "attempt-1", task_generation: "generation-1")

    assert_raises(Hive::Attempts::InvalidReceipt) do
      Hive::Attempts::Record.validate_receipt!(valid.merge("attempt_id" => "other"),
                                               attempt_id: "attempt-1", task_generation: "generation-1")
    end
    assert_raises(Hive::Attempts::InvalidReceipt) do
      Hive::Attempts::Record.validate_receipt!(valid.merge("ended_at" => (NOW - 1).iso8601(6)),
                                               attempt_id: "attempt-1", task_generation: "generation-1")
    end
    broken = Marshal.load(Marshal.dump(valid))
    broken.fetch("output_references").first.delete("sha256")
    assert_raises(Hive::Attempts::InvalidReceipt) do
      Hive::Attempts::Record.validate_receipt!(broken,
                                               attempt_id: "attempt-1", task_generation: "generation-1")
    end
  end

  def test_final_states_are_irreversible
    %w[terminal lost].each do |state|
      record = Hive::Attempts::Record.new(
        Hive::Attempts::Record.launching(**identity, now: NOW, launch_timeout_sec: 30).to_h.merge(
          "state" => state,
          "outcome" => (state == "terminal" ? "failed" : nil),
          "ended_at" => NOW.iso8601(6),
          "loss" => (state == "lost" ? { "reason" => "owner_gone", "at" => NOW.iso8601(6) } : nil),
          "receipt" => (state == "terminal" ? receipt("outcome" => "failed", "exit_status" => 1) : nil)
        )
      )

      assert record.final?
      refute record.transition_allowed?("running")
      refute record.transition_allowed?("launching")
    end
  end

  def test_receipt_validation_rejects_each_required_type
    cases = [
      [ nil, "object" ],
      [ receipt.merge("task_generation" => "other"), "generation" ],
      [ receipt.merge("outcome" => "unknown"), "outcome" ],
      [ receipt.merge("exit_status" => "0"), "exit_status" ],
      [ receipt.merge("final_checkpoint" => {}), "checkpoint" ],
      [ receipt.merge("output_references" => {}), "output_references" ]
    ]
    cases.each do |candidate, message|
      error = assert_raises(Hive::Attempts::InvalidReceipt) do
        Hive::Attempts::Record.validate_receipt!(
          candidate, attempt_id: "attempt-1", task_generation: "generation-1"
        )
      end
      assert_includes error.message, message
    end
  end

  def test_live_transition_matrix_and_record_field_validation
    launching = Hive::Attempts::Record.launching(**identity, now: NOW, launch_timeout_sec: 30)
    assert launching.transition_allowed?("launching")
    assert launching.transition_allowed?("running")
    assert launching.transition_allowed?("lost")
    refute launching.transition_allowed?("terminal")

    running_data = launching.to_h.merge(
      "state" => "running", "claim_deadline" => nil,
      "heartbeat_deadline" => (NOW + 30).iso8601(6),
      "wrapper" => { "pid" => 1 }
    )
    running = Hive::Attempts::Record.new(running_data)
    assert running.transition_allowed?("running")
    assert running.transition_allowed?("terminal")
    assert running.transition_allowed?("lost")
    refute running.transition_allowed?("launching")

    invalid_changes = [
      { "lease_version" => -1 },
      { "retry_charge" => -1 },
      { "current_outputs" => {} },
      { "current_outputs" => [ { "path" => "bad" } ] },
      { "created_at" => "invalid" },
      { "state" => "lost", "claim_deadline" => nil, "loss" => {} },
      { "loss" => { "reason" => "wrong-state", "at" => NOW.iso8601(6) } }
    ]
    invalid_changes.each do |changes|
      assert_raises(Hive::Attempts::InvalidRecord) do
        Hive::Attempts::Record.new(launching.to_h.merge(changes))
      end
    end

    assert_raises(Hive::Attempts::InvalidRecord) do
      Hive::Attempts::Record.new(running_data.merge("heartbeat_deadline" => nil))
    end
  end

  def test_unknown_internal_state_has_no_legal_transition
    record = Hive::Attempts::Record.allocate
    record.instance_variable_set(:@data, { "state" => "unknown" })
    refute record.transition_allowed?("running")
  end

  def test_launch_authority_shape_distinguishes_durable_and_compatibility_records
    valid = Hive::Attempts::Record.launching(**identity, now: NOW, launch_timeout_sec: 30).to_h

    assert_raises(Hive::Attempts::InvalidRecord) do
      Hive::Attempts::Record.new(valid.merge("worker_argv" => [ "" ]))
    end
    assert_raises(Hive::Attempts::InvalidRecord) do
      Hive::Attempts::Record.new(valid.merge("compatibility" => true))
    end
    assert_raises(Hive::Attempts::InvalidRecord) do
      Hive::Attempts::Record.new(valid.merge("worker_argv" => []))
    end
  end

  private

  def identity
    {
      attempt_id: "attempt-1",
      request_id: "request-1",
      predecessor_attempt_id: nil,
      task_id: "42",
      project: "demo",
      task_slug: "durable-task",
      intended_stage: "4-execute",
      task_generation: "generation-1",
      progress_token: "progress-1",
      provider: "codex",
      worker_argv: [ "hive", "run", "durable-task" ],
      claim_capability_digest: Hive::Attempts::Capability.digest("c" * 64),
      starting_revision: "a" * 40,
      retry_charge: 0,
      inherited_outputs: []
    }
  end

  def receipt(overrides = {})
    {
      "attempt_id" => "attempt-1",
      "task_generation" => "generation-1",
      "outcome" => "succeeded",
      "exit_status" => 0,
      "started_at" => NOW.iso8601(6),
      "ended_at" => (NOW + 5).iso8601(6),
      "final_checkpoint" => { "revision" => "b" * 40, "progress_token" => "progress-1" },
      "output_references" => [
        { "path" => "outputs/attempt-1/result.json", "size" => 2, "sha256" => "0" * 64 }
      ],
      "log_reference" => {
        "path" => "logs/attempt-1.frames", "size" => 4, "sha256" => "1" * 64
      }
    }.merge(overrides)
  end
end
