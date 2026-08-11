require "test_helper"
require "hive/attempts/record"
require "hive/provider_health/evidence"

class AttemptsRecordTest < Minitest::Test
  NOW = Time.utc(2026, 7, 16, 12, 0, 0)

  def test_launching_record_exposes_unclaimed_deadline_and_immutable_identity
    record = Hive::Attempts::Record.launching(**identity, now: NOW, launch_timeout_sec: 30)

    assert_equal 4, record["schema_version"]
    assert_equal "launching", record.state
    assert record.live?
    refute record.claimed?
    assert_equal NOW + 30, record.active_deadline
    assert_equal 0, record.lease_version
    assert_equal "attempt-1", record.attempt_id
    assert_equal "generation-1", record.task_generation
    assert_equal "generation-1", record.ownership_generation
    assert_equal 0, record.task_input_epoch
    assert_equal({ "mode" => "legacy" }, record["routing"])
    assert record["routing"].frozen?
  end

  def test_explicit_routing_round_trips_and_is_deeply_frozen
    record = Hive::Attempts::Record.launching(
      **identity.merge(routing: explicit_routing), now: NOW, launch_timeout_sec: 30
    )

    assert_equal "codex-account-a", record["routing"].dig("route", "provider_account_id")
    assert_equal "codex", record["provider"]
    assert record["routing"].frozen?
    assert record["routing"].fetch("route").frozen?
    assert record["routing"].fetch("circuit_generations").frozen?
    assert record["routing"].dig("route", "model").frozen?
    assert_raises(FrozenError) do
      record["routing"].fetch("route")["model"].replace("different-model")
    end

    copy = record.to_h
    copy.fetch("routing").fetch("route")["model"] = "different-model"
    assert_equal "gpt-5.6-sol", record["routing"].dig("route", "model")
  end

  def test_routing_is_required_and_strict_at_every_nested_boundary
    valid = Hive::Attempts::Record.launching(
      **identity.merge(routing: explicit_routing(probe: true)), now: NOW, launch_timeout_sec: 30
    ).to_h

    missing = Marshal.load(Marshal.dump(valid))
    missing.delete("routing")
    assert_raises(Hive::Attempts::InvalidRecord) { Hive::Attempts::Record.new(missing) }

    mutations = [
      ->(routing) { routing["credential"] = "secret" },
      ->(routing) { routing.fetch("decision")["raw_output"] = "secret" },
      ->(routing) { routing.dig("decision", "exclusions").first["message"] = "secret" },
      ->(routing) { routing.fetch("route")["token"] = "secret" },
      ->(routing) { routing.fetch("circuit_generations").first["state"] = "open" },
      ->(routing) { routing.dig("circuit_generations", 0, "scope")["credential"] = "secret" },
      ->(routing) { routing.fetch("probe_bindings").first["raw"] = "secret" }
    ]
    mutations.each do |mutation|
      candidate = Marshal.load(Marshal.dump(valid))
      mutation.call(candidate.fetch("routing"))
      assert_raises(Hive::Attempts::InvalidRecord) do
        Hive::Attempts::Record.new(candidate)
      end
    end

    legacy = Marshal.load(Marshal.dump(valid))
    legacy["routing"] = { "mode" => "legacy", "route" => valid.dig("routing", "route") }
    assert_raises(Hive::Attempts::InvalidRecord) { Hive::Attempts::Record.new(legacy) }
  end

  def test_explicit_routing_rejects_inconsistent_route_circuit_and_probe_bindings
    base = Hive::Attempts::Record.launching(
      **identity.merge(routing: explicit_routing(probe: true)), now: NOW, launch_timeout_sec: 30
    ).to_h
    mutations = [
      ->(routing) { routing.fetch("route")["adapter"] = "claude" },
      ->(routing) { routing.fetch("decision")["policy_digest"] = "b" * 64 },
      ->(routing) { routing.fetch("decision")["decision_id"] = "" },
      ->(routing) { routing.fetch("circuit_generations").pop },
      ->(routing) { routing.dig("circuit_generations", 1, "scope")["model"] = "other-model" },
      ->(routing) { routing.fetch("probe_bindings").first["claim_generation"] = 9 },
      ->(routing) { routing.fetch("probe_bindings").first["attempt_id"] = "other-attempt" },
      ->(routing) { routing.fetch("probe_bindings").first["ownership_fence"] = "other-owner" }
    ]
    mutations.each do |mutation|
      candidate = Marshal.load(Marshal.dump(base))
      mutation.call(candidate.fetch("routing"))
      assert_raises(Hive::Attempts::InvalidRecord) do
        Hive::Attempts::Record.new(candidate)
      end
    end
  end

  def test_explicit_routing_rejects_every_bounded_vector_and_cross_reference_violation
    base = Hive::Attempts::Record.launching(
      **identity.merge(routing: explicit_routing(probe: true)), now: NOW, launch_timeout_sec: 30
    ).to_h
    mutations = [
      ->(routing) { routing.replace("mode" => "future") },
      ->(routing) { routing.fetch("decision")["exclusions"] = {} },
      ->(routing) do
        routing.fetch("decision").fetch("exclusions") <<
          routing.fetch("decision").fetch("exclusions").first.dup
      end,
      ->(routing) do
        routing.fetch("circuit_generations")[1] =
          routing.fetch("circuit_generations")[0].dup
      end,
      ->(routing) { routing["probe_bindings"] = {} },
      ->(routing) { routing.fetch("probe_bindings").first["journal_epoch"] = 99 },
      ->(routing) do
        routing.fetch("probe_bindings") << routing.fetch("probe_bindings").first.dup
      end,
      ->(routing) { routing.fetch("decision").fetch("exclusions").first["detail"] = "" },
      ->(routing) { routing["policy_digest"] = "invalid" }
    ]
    mutations.each do |mutation|
      candidate = Marshal.load(Marshal.dump(base))
      mutation.call(candidate.fetch("routing"))
      assert_raises(Hive::Attempts::InvalidRecord) do
        Hive::Attempts::Record.new(candidate)
      end
    end

    detailed = Marshal.load(Marshal.dump(base))
    detailed.dig("routing", "decision", "exclusions", 0)["detail"] = "bounded detail"
    assert_equal "bounded detail",
                 Hive::Attempts::Record.new(detailed)
                   .to_h.dig("routing", "decision", "exclusions", 0, "detail")

    candidate = Marshal.load(Marshal.dump(base))
    candidate["routing"] = nil
    assert_raises(Hive::Attempts::InvalidRecord) { Hive::Attempts::Record.new(candidate) }
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


    assert_raises(Hive::Attempts::InvalidReceipt) do
      Hive::Attempts::Record.validate_receipt!(
        valid.merge("task_input_epoch" => 2),
        attempt_id: "attempt-1", task_generation: "generation-1", task_input_epoch: 1
      )
    end
    assert_raises(Hive::Attempts::InvalidReceipt) do
      Hive::Attempts::Record.validate_receipt!(
        valid.merge("ownership_generation" => "owner-2"),
        attempt_id: "attempt-1", task_generation: "generation-1",
        ownership_generation: "owner-1"
      )
    end

    assert_raises(Hive::Attempts::InvalidReceipt) do
      Hive::Attempts::Record.validate_receipt!(
        valid.merge("terminal_lease_version" => -1),
        attempt_id: "attempt-1", task_generation: "generation-1"
      )
    end
    assert_raises(Hive::Attempts::InvalidReceipt) do
      Hive::Attempts::Record.validate_receipt!(
        valid.merge("raw_provider_message" => "secret"),
        attempt_id: "attempt-1", task_generation: "generation-1"
      )
    end
    assert_raises(Hive::Attempts::InvalidReceipt) do
      Hive::Attempts::Record.validate_receipt!(
        valid.merge("receipt_version" => 99),
        attempt_id: "attempt-1", task_generation: "generation-1"
      )
    end
    assert_raises(Hive::Attempts::InvalidReceipt) do
      Hive::Attempts::Record.validate_receipt!(
        valid.merge("terminal_lease_version" => 1),
        attempt_id: "attempt-1", task_generation: "generation-1",
        terminal_lease_version: 0
      )
    end
  end

  def test_terminal_receipt_accepts_only_compatible_sanitized_provider_evidence
    routing = explicit_routing
    evidence = provider_evidence(routing: routing)
    valid = receipt(
      "outcome" => "failed", "exit_status" => 1,
      "provider_evidence" => evidence
    )
    assert Hive::Attempts::Record.validate_receipt!(
      valid, attempt_id: "attempt-1", task_generation: "generation-1",
      task_input_epoch: 0, ownership_generation: "generation-1",
      terminal_lease_version: 0, routing: routing
    )
    terminal = Hive::Attempts::Record.new(
      Hive::Attempts::Record.launching(
        **identity.merge(routing: routing), now: NOW, launch_timeout_sec: 30
      ).to_h.merge(
        "state" => "terminal", "outcome" => "failed", "ended_at" => (NOW + 5).iso8601(6),
        "receipt" => valid.merge("outcome" => "failed", "exit_status" => 1)
      )
    )
    assert terminal["receipt"].frozen?
    assert terminal["receipt"].fetch("provider_evidence").frozen?

    assert_raises(Hive::Attempts::InvalidReceipt) do
      Hive::Attempts::Record.validate_receipt!(
        valid.merge("outcome" => "succeeded", "exit_status" => 0),
        attempt_id: "attempt-1", task_generation: "generation-1",
        task_input_epoch: 0, ownership_generation: "generation-1",
        terminal_lease_version: 0, routing: routing
      )
    end

    invalid_evidence = [
      evidence.merge("message" => "raw secret"),
      evidence.merge("fingerprint" => "f" * 64),
      evidence.merge("route_id" => "another-route"),
      evidence.merge("provenance" => "stdout"),
      evidence.merge("scope" => evidence.fetch("scope").merge("model" => "other-model"))
    ]
    invalid_evidence.each do |candidate|
      assert_raises(Hive::Attempts::InvalidReceipt) do
        Hive::Attempts::Record.validate_receipt!(
          valid.merge("provider_evidence" => candidate),
          attempt_id: "attempt-1", task_generation: "generation-1",
          task_input_epoch: 0, ownership_generation: "generation-1",
          terminal_lease_version: 0, routing: routing
        )
      end
    end

    assert_raises(Hive::Attempts::InvalidReceipt) do
      Hive::Attempts::Record.validate_receipt!(
        valid, attempt_id: "attempt-1", task_generation: "generation-1",
        terminal_lease_version: 0, routing: { "mode" => "legacy" }
      )
    end
  end

  def test_provider_evidence_rejects_class_hint_reference_and_scope_invariants
    routing = explicit_routing
    valid = provider_evidence(routing: routing)
    protected = [ valid.fetch("source_reference") ]
    mutations = [
      valid.merge("failure_class" => "authentication"),
      valid.merge("reset_hint_seconds" => -1),
      valid.merge("scope" => valid.fetch("scope").merge("kind" => "future"))
    ]
    mutations.each do |candidate|
      assert_raises(Hive::Attempts::InvalidReceipt) do
        Hive::Attempts::Record.send(
          :validate_provider_evidence!, candidate,
          routing: routing, protected_references: protected
        )
      end
    end

    long_reference = valid.fetch("source_reference").merge("path" => "x" * 513)
    assert_raises(Hive::Attempts::InvalidReceipt) do
      Hive::Attempts::Record.send(
        :validate_provider_evidence!, valid.merge("source_reference" => long_reference),
        routing: routing, protected_references: [ long_reference ]
      )
    end
    unprotected = valid.fetch("source_reference").merge("path" => "logs/other.frames")
    assert_raises(Hive::Attempts::InvalidReceipt) do
      Hive::Attempts::Record.send(
        :validate_provider_evidence!, valid.merge("source_reference" => unprotected),
        routing: routing, protected_references: protected
      )
    end
    malformed = valid.fetch("source_reference").reject { |key, _| key == "sha256" }
    assert_raises(Hive::Attempts::InvalidReceipt) do
      Hive::Attempts::Record.send(
        :validate_provider_evidence!, valid.merge("source_reference" => malformed),
        routing: routing, protected_references: protected
      )
    end

    assert_equal [ { "a" => 1 } ], Hive::Attempts::Record.send(
      :canonical_value, [ { "a" => 1 } ]
    )
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
      { "ownership_generation" => "" },
      { "task_input_epoch" => -1 },
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

  def test_launch_authority_requires_current_durable_fields_only
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

  def test_legacy_v2_record_is_rejected_until_migrated
    legacy = Hive::Attempts::Record.launching(**identity, now: NOW, launch_timeout_sec: 30).to_h
    legacy["schema_version"] = 2
    legacy.delete("subject")

    error = assert_raises(Hive::Attempts::InvalidRecord) do
      Hive::Attempts::Record.new(legacy)
    end
    assert_includes error.message, "unsupported schema_version 2"
  end

  def test_task_subject_must_match_the_legacy_identity_fields
    data = Hive::Attempts::Record.launching(
      **identity, now: NOW, launch_timeout_sec: 30
    ).to_h
    data["subject"] = data.fetch("subject").merge(
      "task_slug" => "another-task"
    )

    error = assert_raises(Hive::Attempts::InvalidRecord) do
      Hive::Attempts::Record.new(data)
    end
    assert_match(/subject has incompatible identity/, error.message)
  end

  def test_module_hook_subject_is_first_class_and_strict
    subject = {
      "kind" => "module_hook", "project_id" => "project-1", "module" => "patrol",
      "hook" => "task-completed", "event_id" => "evt-1", "occurrence_id" => "evt-1",
      "event_name" => "task.completed", "module_generation" => "a" * 40,
      "configuration_digest" => "b" * 64, "grant_digest" => "c" * 64
    }
    record = Hive::Attempts::Record.launching(
      **identity.merge(task_id: nil, task_slug: "module-patrol-task", intended_stage: "module-hook"),
      subject: subject, now: NOW, launch_timeout_sec: 30
    )

    assert record.module_hook?
    assert_equal subject, record.subject
    assert_raises(Hive::Attempts::InvalidRecord) do
      Hive::Attempts::Record.new(record.to_h.merge("subject" => subject.merge("grant_digest" => "secret")))
    end
    assert_raises(Hive::Attempts::InvalidRecord) do
      Hive::Attempts::Record.new(record.to_h.merge("subject" => { "kind" => "future" }))
    end
  end

  def test_unsupported_schema_versions_are_rejected
    [ 0, 1, 2, 99 ].each do |schema_version|
      invalid = Hive::Attempts::Record.launching(
        **identity, now: NOW, launch_timeout_sec: 30
      ).to_h.merge("schema_version" => schema_version)

      error = assert_raises(Hive::Attempts::InvalidRecord) do
        Hive::Attempts::Record.new(invalid)
      end
      assert_includes error.message, "unsupported schema_version"
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
      routing: { "mode" => "legacy" },
      worker_argv: [ "hive", "run", "durable-task" ],
      claim_capability_digest: Hive::Attempts::Capability.digest("c" * 64),
      starting_revision: "a" * 40,
      retry_charge: 0,
      inherited_outputs: []
    }
  end

  def explicit_routing(probe: false)
    account_scope = {
      "kind" => "provider_account", "provider_account_id" => "codex-account-a", "model" => nil
    }
    model_scope = {
      "kind" => "model", "provider_account_id" => "codex-account-a", "model" => "gpt-5.6-sol"
    }
    bindings = if probe
                 [
                   {
                     "scope" => model_scope,
                     "journal_epoch" => 2,
                     "observed_generation" => 7,
                     "claim_generation" => 8,
                     "attempt_id" => "attempt-1",
                     "task_generation" => "generation-1",
                     "ownership_fence" => "generation-1"
                   }
                 ]
    else
                 []
    end
    {
      "mode" => "explicit",
      "policy_digest" => "a" * 64,
      "decision" => {
        "decision_id" => "decision-1",
        "policy_digest" => "a" * 64,
        "decided_at" => NOW.iso8601(6),
        "exclusions" => [
          { "route_id" => "route-0", "reason" => "circuit_cooldown", "detail" => nil }
        ]
      },
      "route" => {
        "route_id" => "route-1",
        "provider_account_id" => "codex-account-a",
        "adapter" => "codex",
        "launch_binding_id" => "codex-home-a",
        "model" => "gpt-5.6-sol",
        "effort" => "high"
      },
      "circuit_generations" => [
        { "scope" => account_scope, "journal_epoch" => 1, "observed_generation" => 4 },
        { "scope" => model_scope, "journal_epoch" => 2, "observed_generation" => 7 }
      ],
      "probe_bindings" => bindings
    }
  end

  def provider_evidence(routing:)
    route_data = routing.fetch("route")
    route = Hive::ProviderHealth::RouteIdentity.new(
      route_id: route_data.fetch("route_id"),
      account_id: route_data.fetch("provider_account_id"),
      adapter: route_data.fetch("adapter"),
      launch_binding_id: route_data.fetch("launch_binding_id"),
      model_id: route_data.fetch("model")
    )
    Hive::ProviderHealth::Evidence.new(
      scope: Hive::ProviderHealth::Scope.model(
        account_id: route.account_id, model_id: route.model_id
      ),
      failure_class: "model_capacity",
      provenance: "codex_jsonl_transport",
      route: route,
      reset_hint_seconds: 30,
      source_reference: receipt.fetch("log_reference"),
      attempt_id: "attempt-1"
    ).to_h
  end

  def receipt(overrides = {})
    {
      "receipt_version" => 1,
      "terminal_lease_version" => 0,
      "attempt_id" => "attempt-1",
      "task_generation" => "generation-1",
      "ownership_generation" => "generation-1",
      "task_input_epoch" => 0,
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
      },
      "provider_evidence" => nil
    }.merge(overrides)
  end
end
