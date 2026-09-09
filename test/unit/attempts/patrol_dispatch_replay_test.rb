require "test_helper"
require "json_schemer"
require "support/patrol_dispatch_replay"
require "hive/patrol_fix/attempt_diagnostic"

class PatrolDispatchReplayTest < Minitest::Test
  include HiveTestHelper

  FIXTURE = File.expand_path(
    "../../fixtures/attempts/patrol_dispatch_spree.v1.json",
    __dir__
  ).freeze

  def test_replay_preserves_incident_totals_and_failure_classes
    result = replay.replay

    assert_equal 600, result.metrics.fetch("accepted_attempts")
    assert_equal 600, result.metrics.fetch("charged_attempts")
    assert_equal 598, result.metrics.fetch("patrol_fix_attempts")
    assert_equal 2, result.metrics.fetch("coding_attempts")
    assert_equal 153, result.metrics.fetch("failed_attempts")
    assert_equal 447, result.metrics.fetch("succeeded_attempts")
    assert_equal(
      {
        [ "1-inbox", "succeeded" ] => 5,
        [ "2-brainstorm", "succeeded" ] => 2,
        [ "2-fix", "failed" ] => 58,
        [ "2-fix", "succeeded" ] => 179,
        [ "3-validate", "failed" ] => 35,
        [ "3-validate", "succeeded" ] => 147,
        [ "4-review", "failed" ] => 55,
        [ "4-review", "succeeded" ] => 86,
        [ "5-publish", "failed" ] => 5,
        [ "5-publish", "succeeded" ] => 28
      },
      result.attempts.group_by { |attempt| [ attempt.fetch("stage"), attempt.fetch("outcome") ] }
            .transform_values(&:length)
    )
    assert_equal(
      {
        "agent_exit_nonzero" => 71,
        "fix_report_invalid" => 2,
        "fix_worktree_dirty" => 2,
        "protected_git_config_tamper" => 11,
        "secret_policy_publish_blocked" => 3,
        "state_git_index_lock" => 4,
        "validation_mutation" => 1,
        "worktree_head_custody_mismatch" => 59
      },
      result.failure_counts
    )
  end

  def test_replay_preserves_generation_stage_repeat_cohort
    result = replay.replay

    assert_equal 459, result.metrics.fetch("unique_generation_stage_identities")
    assert_equal 88, result.metrics.fetch("repeated_generation_stage_identities")
    assert_equal 141, result.metrics.fetch("repeat_launches")
    assert_equal 5, result.metrics.fetch("max_attempts_for_identity")
    assert_equal(
      { 1 => 371, 2 => 44, 3 => 36, 4 => 7, 5 => 1 },
      result.attempts.group_by { |attempt| attempt.fetch("generation_stage_identity") }
            .transform_values(&:length).values.tally.sort.to_h
    )
  end

  def test_terminal_envelopes_are_separate_from_expected_normalized_codes
    replay.failure_cohorts.each_with_index do |cohort, index|
      envelope = cohort.fetch("terminal_envelope")

      refute envelope.key?("failure_code")
      refute envelope.key?("expected_normalized_code")
      %w[
        status exit_code timed_out cancelled signal provider provider_failure
        report_status firewall_status custody_status
      ].each { |key| assert envelope.key?(key), "#{cohort.fetch("cohort")} missing #{key}" }
      assert_match(/\A[a-z][a-z0-9_]*\z/, cohort.fetch("expected_normalized_code"))
      diagnostic = Hive::PatrolFix::AttemptDiagnostic.normalize(
        envelope,
        stage: "incident-replay",
        task_generation: "incident-generation",
        attempt_id: format("incident-attempt-%03d", index + 1),
        recorded_at: Time.utc(2026, 8, 26)
      )
      assert_equal cohort.fetch("expected_normalized_code"), diagnostic.fetch("code")
    end
  end

  def test_normalizer_bounds_and_redacts_detail_and_omits_it_when_redaction_fails
    token = "ghp_" + "aB3dE6gH9jK2mN5pQ8sT1vW4yZ7bC0eF3hI6"
    detail = "\e[31mprovider failed #{token} \xFF".b + ("x" * 8_000)
    diagnostic = Hive::PatrolFix::AttemptDiagnostic.normalize(
      {
        "status" => "error", "exit_code" => 1, "timed_out" => false,
        "cancelled" => false, "signal" => nil, "detail" => detail
      },
      stage: "2-fix", task_generation: "generation-1",
      attempt_id: "attempt-1",
      recorded_at: Time.utc(2026, 8, 26)
    )

    assert_equal "agent_exit_nonzero", diagnostic.fetch("code")
    assert_equal 1, diagnostic.fetch("secret_policy_version"),
                 "a scanner replacement must not invalidate existing diagnostic receipts"
    assert_operator diagnostic.fetch("detail").bytesize, :<=,
                    Hive::PatrolFix::AttemptDiagnostic::MAX_DETAIL_BYTES
    assert diagnostic.fetch("detail").valid_encoding?
    refute_includes diagnostic.fetch("detail"), "\e[31m"
    refute_includes diagnostic.fetch("detail"), token
    assert_includes diagnostic.fetch("detail"), "[REDACTED:github_token]"

    failed = Hive::PatrolFix::AttemptDiagnostic.normalize(
      {
        "status" => "error", "exit_code" => 1, "timed_out" => false,
        "cancelled" => false, "signal" => nil, "detail" => "private detail"
      },
      stage: "2-fix", task_generation: "generation-1",
      attempt_id: "attempt-2",
      recorded_at: Time.utc(2026, 8, 26),
      redactor: ->(_text) { raise "redactor unavailable" }
    )
    assert_equal "agent_exit_nonzero", failed.fetch("code")
    assert_nil failed.fetch("detail")
    assert_equal "failed", failed.fetch("redaction_status")
  end

  def test_failure_code_must_be_snake_case
    assert_raises(Hive::PatrolFix::AttemptDiagnostic::InvalidDiagnostic) do
      Hive::PatrolFix::AttemptDiagnostic.normalize(
        { "status" => "error", "provider_failure" => "Capacity.Exhausted" },
        stage: "2-fix", task_generation: "generation-1",
        attempt_id: "attempt-1",
        recorded_at: Time.utc(2026, 8, 26)
      )
    end
  end

  def test_transport_status_must_be_from_the_closed_protocol
    assert_raises(Hive::PatrolFix::AttemptDiagnostic::InvalidDiagnostic) do
      Hive::PatrolFix::AttemptDiagnostic.normalize(
        { "status" => "error", "exit_code" => 1 },
        stage: "2-fix", task_generation: "generation-1",
        attempt_id: "attempt-1", recorded_at: Time.utc(2026, 8, 26),
        transport_status: "future_state"
      )
    end
  end

  def test_secret_shaped_metadata_invalidates_the_entire_diagnostic
    secret = "ghp_" + "aB3dE6gH9jK2mN5pQ8sT1vW4yZ7bC0eF3hI6"
    base = Hive::PatrolFix::AttemptDiagnostic.normalize(
      {
        "phase" => "managed_agent", "status" => "error", "exit_code" => 1,
        "provider" => "codex", "provider_failure" => "provider_error",
        "provider_provenance" => "codex_jsonl_transport",
        "retry_at" => 30, "report_parser" => "fix_report"
      },
      stage: "2-fix", task_generation: "generation-1",
      attempt_id: "attempt-1", recorded_at: Time.utc(2026, 8, 26)
    )
    mutations = [
      ->(row) { row.fetch("provider")["name"] = secret },
      ->(row) { row.fetch("provider")["failure_class"] = secret },
      ->(row) { row.fetch("provider")["retry_hint"] = secret },
      ->(row) { row.fetch("provider")["provenance"] = secret },
      ->(row) { row["agent_reason"] = secret },
      ->(row) { row["report_parser"] = secret },
      ->(row) { row["status"] = secret }
    ]

    mutations.each do |mutate|
      candidate = JSON.parse(JSON.generate(base))
      mutate.call(candidate)
      error = assert_raises(Hive::PatrolFix::AttemptDiagnostic::InvalidDiagnostic) do
        Hive::PatrolFix::AttemptDiagnostic.validate!(
          candidate, require_log_reference: false
        )
      end
      assert_match(/secret-pattern text/, error.message)
    end
  end

  def test_validator_rejects_wrong_scalar_types_that_the_schema_rejects
    base = Hive::PatrolFix::AttemptDiagnostic.normalize(
      {
        "status" => "error", "exit_code" => 1, "provider" => "codex",
        "provider_failure" => "provider_error"
      },
      stage: "2-fix", task_generation: "generation-1",
      attempt_id: "attempt-1", recorded_at: Time.utc(2026, 8, 26)
    )
    mutations = [
      ->(row) { row["status"] = 7 },
      ->(row) { row["agent_reason"] = 7 },
      ->(row) { row.fetch("provider")["name"] = 7 },
      ->(row) { row.fetch("provider")["retry_hint"] = 7 }
    ]
    schema = JSONSchemer.schema(JSON.parse(File.read(File.expand_path(
      "../../../schemas/hive-patrol-fix-attempt-diagnostic.v1.json", __dir__
    ))))

    mutations.each do |mutate|
      candidate = JSON.parse(JSON.generate(base))
      mutate.call(candidate)
      refute schema.valid?(candidate)
      assert_raises(Hive::PatrolFix::AttemptDiagnostic::InvalidDiagnostic) do
        Hive::PatrolFix::AttemptDiagnostic.validate!(
          candidate, require_log_reference: false
        )
      end
    end
  end

  def test_finalizer_binds_identity_and_applies_authoritative_provider_signal
    draft = Hive::PatrolFix::AttemptDiagnostic.normalize(
      { "status" => "error", "exit_code" => 1, "detail" => "safe detail" },
      stage: "2-fix", task_generation: "generation-1",
      attempt_id: "attempt-1", recorded_at: Time.utc(2026, 8, 26)
    )
    log_reference = {
      "path" => "logs/attempt-1.frames", "size" => 12, "sha256" => "a" * 64
    }
    provider_signal = {
      "failure_class" => "model_capacity", "reset_hint_seconds" => 30,
      "provenance" => "codex_jsonl_transport"
    }

    finalized = Hive::PatrolFix::AttemptDiagnostic.finalize(
      draft, log_reference: log_reference,
      expected_attempt_id: "attempt-1", expected_stage: "2-fix",
      expected_task_generation: "generation-1", provider_signal: provider_signal,
      provider_name: "codex", redactor: ->(_text) { raise "redactor unavailable" }
    )

    assert_equal "model_capacity", finalized.fetch("code")
    assert_equal "provider", finalized.fetch("owner")
    assert_equal "codex", finalized.dig("provider", "name")
    assert_equal "30", finalized.dig("provider", "retry_hint")
    assert_equal "failed", finalized.fetch("redaction_status")
    assert_equal log_reference, finalized.fetch("log_reference")

    assert_raises(Hive::PatrolFix::AttemptDiagnostic::InvalidDiagnostic) do
      Hive::PatrolFix::AttemptDiagnostic.finalize(
        draft, log_reference: log_reference,
        expected_attempt_id: "other-attempt", expected_stage: "2-fix",
        expected_task_generation: "generation-1"
      )
    end
    assert_raises(Hive::PatrolFix::AttemptDiagnostic::InvalidDiagnostic) do
      Hive::PatrolFix::AttemptDiagnostic.finalize(
        draft, log_reference: log_reference,
        expected_attempt_id: "attempt-1", expected_stage: "2-fix",
        expected_task_generation: "generation-1",
        provider_signal: { "failure_class" => "provider_error" }, provider_name: "codex"
      )
    end
  end

  def test_validator_rejects_each_fail_closed_document_shape
    base = Hive::PatrolFix::AttemptDiagnostic.normalize(
      { "status" => "error", "exit_code" => 1 },
      stage: "2-fix", task_generation: "generation-1",
      attempt_id: "attempt-1", recorded_at: Time.utc(2026, 8, 26)
    )
    invalid_mutations = [
      ->(row) { row.delete("owner") },
      ->(row) { row["timed_out"] = nil },
      ->(row) { row["detail"] = [] },
      ->(row) { row["redaction_status"] = "future" },
      ->(row) { row["provider"] = { "unexpected" => nil } },
      ->(row) { row["stage"] = "" }
    ]

    invalid_mutations.each do |mutate|
      candidate = JSON.parse(JSON.generate(base))
      mutate.call(candidate)
      assert_raises(Hive::PatrolFix::AttemptDiagnostic::InvalidDiagnostic) do
        Hive::PatrolFix::AttemptDiagnostic.validate!(candidate, require_log_reference: false)
      end
    end

    candidate = JSON.parse(JSON.generate(base))
    candidate["log_reference"] = {
      "path" => "logs/attempt-1.frames", "size" => 12, "sha256" => "a" * 64
    }
    assert Hive::PatrolFix::AttemptDiagnostic.validate!(candidate, require_log_reference: false)

    candidate["log_reference"]["size"] = -1
    assert_raises(Hive::PatrolFix::AttemptDiagnostic::InvalidDiagnostic) do
      Hive::PatrolFix::AttemptDiagnostic.validate!(candidate, require_log_reference: false)
    end
    assert_raises(Hive::PatrolFix::AttemptDiagnostic::InvalidDiagnostic) do
      Hive::PatrolFix::AttemptDiagnostic.normalize(
        { "status" => "error" }, stage: "2-fix", task_generation: "generation-1",
        attempt_id: "attempt-1", recorded_at: "not-a-time"
      )
    end
  end

  def test_normalizer_maps_remaining_provider_kinds_and_terminal_fallback
    {
      "provider_limit" => "provider_limit",
      "provider_error" => "provider_error",
      "model_output_limit" => "model_output_limit"
    }.each_with_index do |(kind, code), index|
      diagnostic = Hive::PatrolFix::AttemptDiagnostic.normalize(
        { "status" => "error", "provider_error" => { "kind" => kind } },
        stage: "2-fix", task_generation: "generation-1",
        attempt_id: "attempt-provider-#{index}", recorded_at: Time.utc(2026, 8, 26)
      )
      assert_equal code, diagnostic.fetch("code")
    end

    terminal = Hive::PatrolFix::AttemptDiagnostic.normalize(
      { "status" => "error" }, stage: "2-fix", task_generation: "generation-1",
      attempt_id: "attempt-terminal", recorded_at: Time.utc(2026, 8, 26)
    )
    assert_equal "agent_terminal_failure", terminal.fetch("code")
  end

  def test_terminal_process_states_normalize_to_distinct_codes
    cases = {
      "agent_timeout" => { "timed_out" => true, "cancelled" => true, "exit_code" => 124 },
      "agent_cancelled" => { "cancelled" => true, "exit_code" => 143 },
      "agent_signalled" => { "signal" => "KILL", "exit_code" => 137 },
      "agent_exit_nonzero" => { "exit_code" => 23 }
    }

    cases.each_with_index do |(code, fields), index|
      diagnostic = Hive::PatrolFix::AttemptDiagnostic.normalize(
        { "status" => "error", **fields },
        stage: "2-fix", task_generation: "generation-1",
        attempt_id: "attempt-#{index}",
        recorded_at: Time.utc(2026, 8, 26)
      )
      assert_equal code, diagnostic.fetch("code")
    end
  end

  def test_current_accounting_charges_started_failures_and_refunds_only_existing_cases
    assert_equal(
      {
        "started_failure" => true,
        "started_success" => true,
        "unstarted_loss" => false,
        "started_tempfail" => false
      },
      replay.accounting_results
    )
  end

  def test_current_pool_keeps_later_stage_order_but_starves_healthy_and_non_patrol_work
    projection = replay.current_pool_at(cap: 600)

    assert_equal "patrol_progress_later_stage", projection.fetch("candidates").first.fetch("class")
    assert projection.fetch("candidates").all? { |candidate| candidate.fetch("admitted") == false }
    assert_includes projection.fetch("starved_classes"), "patrol_progress_later_stage"
    assert_includes projection.fetch("starved_classes"), "patrol_progress_first_attempt"
    assert_includes projection.fetch("starved_classes"), "non_patrol_first_attempt"

    temporary = replay.current_pool_at(cap: 1_000)
    assert_equal 400, temporary.fetch("remaining")
    assert temporary.fetch("candidates").all? { |candidate| candidate.fetch("admitted") }
  end

  def test_operational_metadata_keeps_temporary_cap_and_rollback_portable
    operational = replay.operational

    assert_equal 1_000, operational.fetch("temporary_daily_cap")
    assert_equal 600, operational.fetch("rollback_daily_cap")
    assert_equal "stable_24_hour_final_soak", operational.dig("exit_gate", "requires")
    assert_equal true, operational.dig("rollback", "preserve_accepted_attempts")
    assert_equal false, replay.non_patrol_demand.fetch("available")
    assert_match(/workflow identity/i, replay.non_patrol_demand.fetch("uncertainty"))
  end

  def test_replay_is_byte_deterministic
    first = replay.replay
    second = replay.replay

    assert_equal first.digest, second.digest
    assert_equal first.attempts, second.attempts
  end

  def test_malformed_and_oversized_fixtures_are_rejected
    error = fixture_error("{")
    assert_match(/malformed JSON/, error.message)

    oversized = "{" + ("x" * HiveTestSupport::PatrolDispatchReplay::MAX_BYTES)
    error = fixture_error(oversized)
    assert_match(/exceeds/, error.message)
  end

  def test_secret_bearing_non_utf8_and_host_specific_fixtures_are_rejected
    token = "ghp_" + "aB3dE6gH9jK2mN5pQ8sT1vW4yZ7bC0eF3hI6"
    error = fixture_error(JSON.generate("diagnostic" => token))
    assert_match(/secret-bearing/, error.message)

    error = fixture_error("{\"diagnostic\":\"\xFF\"}".b)
    assert_match(/UTF-8/, error.message)

    error = fixture_error(JSON.generate("evidence_path" => "/home/operator/private.log"))
    assert_match(/host-specific path/, error.message)
  end

  def test_future_lane_containment_assertion_is_an_expected_failure
    error = assert_raises(Minitest::Assertion) do
      assert_empty replay.future_containment_violations(cap: 600)
    end

    assert_match(/non-Patrol work is starved/, error.message)
  end

  private

  def replay
    HiveTestSupport::PatrolDispatchReplay.new(FIXTURE)
  end

  def fixture_error(bytes)
    with_tmp_dir do |dir|
      path = File.join(dir, "incident.json")
      File.binwrite(path, bytes)
      return assert_raises(HiveTestSupport::PatrolDispatchReplay::InvalidFixture) do
        HiveTestSupport::PatrolDispatchReplay.new(path)
      end
    end
  end
end
