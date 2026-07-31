require "test_helper"
require "json_schemer"
require "hive/modules/migration/qualification_lane_result"

class ModulesMigrationQualificationLaneResultTest < Minitest::Test
  RESULT =
    Hive::Modules::Migration::QualificationLaneResult
  RUN_ID = "patrol-#{"a" * 64}".freeze
  STARTED = Time.utc(2026, 7, 30, 10)

  def test_passed_blocked_failed_and_timeout_results_are_canonical
    rows = [
      [ "passed", 0, nil ],
      [ "blocked", nil, "live_lane_not_authorized" ],
      [ "failed", 70, "candidate_execution_failed" ],
      [ "timeout", nil, "lane_timeout" ]
    ]

    rows.each do |status, exit_code, reason|
      result = build(
        status: status, exit_code: exit_code,
        failure_reason: reason
      )
      bytes = RESULT.canonical(result.to_h)

      assert_equal result.to_h, RESULT.load(bytes).to_h
      assert_predicate result.payload, :frozen?
      assert_empty schema.validate(result.to_h).to_a
    end
  end

  def test_outcome_fields_are_status_specific
    invalid = [
      [ "passed", nil, nil ],
      [ "passed", 0, "internal_error" ],
      [ "blocked", 1, "provider_unavailable" ],
      [ "blocked", nil, "provider_failed" ],
      [ "failed", 0, "scenario_failed" ],
      [ "failed", 1, "provider_unavailable" ],
      [ "timeout", nil, "scenario_failed" ]
    ]

    invalid.each do |status, exit_code, reason|
      assert_raises(Hive::ConfigError) do
        build(
          status: status, exit_code: exit_code,
          failure_reason: reason
        )
      end
    end
  end

  def test_failure_reason_rejects_prose_controls_secrets_and_oversize
    [
      "provider failed with token sk-or-v1-secret",
      "provider_failed\nOPENROUTER_API_KEY=secret",
      "provider_failed\0",
      "x" * (RESULT::MAX_BYTES + 1),
      "provider-failed",
      "PROVIDER_FAILED"
    ].each do |reason|
      assert_raises(Hive::ConfigError) do
        build(
          status: "failed", exit_code: 1,
          failure_reason: reason
        )
      end
    end
  end

  def test_load_rejects_noncanonical_extra_and_invalid_time_or_identity
    valid = build.to_h
    mutations = [
      valid.merge("extra" => true),
      valid.merge("run_id" => "../latest"),
      valid.merge("lane" => "source"),
      valid.merge("target_sha256" => "no"),
      valid.merge("started_at" => "2026-07-30T10:00:00Z"),
      valid.merge(
        "ended_at" => (STARTED - 1).iso8601(6)
      )
    ]
    mutations.each do |payload|
      assert_raises(Hive::ConfigError) do
        RESULT.load(RESULT.canonical(payload))
      end
    end

    pretty = JSON.pretty_generate(valid)
    assert_raises(Hive::ConfigError) { RESULT.load(pretty) }
    assert_raises(Hive::ConfigError) do
      RESULT.load(" " * (RESULT::MAX_BYTES + 1))
    end
  end

  private

  def build(status: "passed", exit_code: 0,
            failure_reason: nil)
    RESULT.build(
      run_id: RUN_ID,
      lane: "deterministic",
      status: status,
      started_at: STARTED,
      ended_at: STARTED + 3,
      target_sha256: "b" * 64,
      exit_code: exit_code,
      failure_reason: failure_reason
    )
  end

  def schema
    @schema ||= JSONSchemer.schema(
      JSON.parse(
        File.binread(
          Hive::Schemas.schema_path(
            "hive-patrol-qualification-lane-result"
          )
        )
      )
    )
  end
end
