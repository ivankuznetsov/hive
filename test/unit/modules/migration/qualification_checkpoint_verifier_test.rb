require "test_helper"
require "hive/modules/migration/qualification_checkpoint_verifier"
require_relative "../../../support/qualification_run_fixture"

class ModulesMigrationQualificationCheckpointVerifierTest <
    Minitest::Test
  include HiveTestHelper
  include QualificationRunFixture

  VERIFIER =
    Hive::Modules::Migration::QualificationCheckpointVerifier

  def test_accepts_a_semantically_bound_canonical_event
    with_event_root(valid_event) do |runtime|
      records = VERIFIER.new.__send__(
        :event_records,
        runtime
      )

      assert_equal [ valid_event ], records
    end
  end

  def test_rejects_semantic_event_near_misses
    mutations = {
      extra_key: ->(event) { event["unknown"] = true },
      event_name: ->(event) { event["event_name"] = "task_completed" },
      project: ->(event) { event["project"] = "other" },
      source: ->(event) { event.dig("source", "id").replace("other") },
      idempotency: lambda do |event|
        event["idempotency_key"] = "patrol-finalized:other"
      end,
      occurred_at: lambda do |event|
        event["occurred_at"] =
          (Time.iso8601(event.fetch("occurred_at")) + 1).iso8601(6)
      end,
      recorded_at: lambda do |event|
        event["recorded_at"] =
          Time.iso8601(event.fetch("recorded_at")).iso8601
      end,
      event_id: ->(event) { event["event_id"] = "evt-#{"f" * 64}" }
    }

    mutations.each do |name, mutation|
      event = valid_event
      mutation.call(event)
      with_event_root(event) do |runtime|
        error = assert_raises(
          Hive::ConfigError,
          "expected #{name} to fail"
        ) do
          VERIFIER.new.__send__(
            :event_records,
            runtime
          )
        end
        assert_equal(
          "patrol qualification checkpoint state is malformed",
          error.message,
          name
        )
      end
    end
  end

  private

  def valid_event
    fixture = qualification_run_fixture
    JSON.parse(JSON.generate(
      qualification_scenario_observations(
        fixture,
        lane: "deterministic"
      ).dig("observations", 0, "event")
    ))
  end

  def with_event_root(event)
    with_tmp_dir do |root|
      runtime = File.join(root, "module-runtime")
      events = File.join(runtime, "events")
      FileUtils.mkdir_p(events, mode: 0o700)
      File.chmod(0o700, runtime)
      File.chmod(0o700, events)
      original_id =
        qualification_scenario_observations(
          qualification_run_fixture,
          lane: "deterministic"
        ).dig("observations", 0, "event", "event_id")
      path = File.join(events, "#{original_id}.json")
      File.binwrite(
        path,
        Hive::WorkflowPackage::CanonicalJSON.generate(event)
      )
      File.chmod(0o600, path)
      yield runtime
    end
  end
end
