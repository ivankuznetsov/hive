require "test_helper"
require "support/patrol_dispatch_replay"

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
        "agent_result_generic" => 53,
        "diagnostic_missing" => 18,
        "fix_report_invalid" => 2,
        "fix_worktree_dirty" => 2,
        "protected_git_config_mutation" => 11,
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
    replay.failure_cohorts.each do |cohort|
      envelope = cohort.fetch("terminal_envelope")

      refute envelope.key?("failure_code")
      refute envelope.key?("expected_normalized_code")
      %w[
        status exit_code timed_out cancelled signal provider provider_failure
        report_status firewall_status custody_status
      ].each { |key| assert envelope.key?(key), "#{cohort.fetch("cohort")} missing #{key}" }
      assert_match(/\A[a-z][a-z0-9_]*\z/, cohort.fetch("expected_normalized_code"))
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
    token = "github" + "_pat_" + ("A" * 24)
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
