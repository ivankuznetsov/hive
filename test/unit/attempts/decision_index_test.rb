require_relative "../../test_helper"
require "hive/attempts/decision_index"
require "hive/provider_routing"

class AttemptsDecisionIndexTest < Minitest::Test
  NOW = Time.utc(2026, 8, 10, 12)

  def setup
    @root = Dir.mktmpdir("attempt-decision-index")
    @index = Hive::Attempts::DecisionIndex.new(root: @root)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_routing_decision_round_trips_as_one_sanitized_operational_projection
    decision = selected_decision("decision-1")

    recorded = @index.record_routing_decision(
      decision: decision,
      task_generation: "generation-1",
      subject: subject,
      project: "demo",
      attempt_id: "attempt-1"
    )
    restarted = Hive::Attempts::DecisionIndex.new(root: @root)

    assert_equal decision.to_h, recorded
    assert_equal decision.to_h, restarted.routing_decision(
      task_generation: "generation-1",
      subject: subject
    )
    assert_equal [
      {
        "task_generation" => "generation-1",
        "subject" => subject,
        "project" => "demo",
        "attempt_id" => "attempt-1",
        "decision" => decision.to_h
      }
    ], restarted.routing_decisions
    refute_includes all_bytes, "stdout"
    refute_includes all_bytes, "credential"
  end

  def test_new_admission_observation_replaces_the_previous_projection
    @index.record_routing_decision(
      decision: selected_decision("decision-1"),
      task_generation: "generation-1",
      subject: subject,
      project: "demo",
      attempt_id: "attempt-1"
    )
    latest = Hive::ProviderRouting::Decision.no_route(
      request: request,
      considered: [ route ],
      exclusions: [
        Hive::ProviderRouting::Decision::Exclusion.new(
          route_id: route.id,
          reason: "manual_block"
        )
      ],
      decision_id: "decision-2",
      decided_at: NOW + 1
    )

    @index.record_routing_decision(
      decision: latest,
      task_generation: "generation-1",
      subject: subject,
      project: "demo"
    )

    assert_equal latest.to_h, @index.routing_decision(
      task_generation: "generation-1",
      subject: subject
    )
  end

  def test_corrupt_or_colliding_projection_fails_closed
    @index.record_routing_decision(
      decision: selected_decision("decision-1"),
      task_generation: "generation-1",
      subject: subject,
      project: "demo",
      attempt_id: "attempt-1"
    )
    key = { "task_generation" => "generation-1", "subject" => subject }
    File.write(@index.path_for("routing-decision", key), "{}\n")

    assert_raises(Hive::Attempts::StoreError) do
      @index.routing_decision(task_generation: "generation-1", subject: subject)
    end
  end

  def test_routing_decision_input_and_projection_limits_fail_closed
    assert_raises(Hive::Attempts::StoreError) do
      @index.record_routing_decision(
        decision: Object.new, task_generation: "generation-1",
        subject: subject, project: "demo"
      )
    end
    assert_raises(Hive::Attempts::StoreError) do
      @index.record_routing_decision(
        decision: selected_decision("decision-1"),
        task_generation: "other-generation", subject: subject,
        project: "demo", attempt_id: "attempt-1"
      )
    end
    [ nil, 0, Hive::Attempts::DecisionIndex::MAX_ROUTING_PROJECTIONS + 1 ].each do |limit|
      assert_raises(Hive::Attempts::StoreError) { @index.routing_decisions(limit: limit) }
    end
  end

  def test_enumerated_projection_rejects_missing_keys_malformed_json_and_unsortable_rows
    assert_raises(Hive::Attempts::StoreError) do
      @index.send(
        :parse_enumerated_entry,
        JSON.generate("key" => "not-an-object"),
        expected_kind: Hive::Attempts::DecisionIndex::ROUTING_DECISION
      )
    end
    assert_raises(Hive::Attempts::StoreError) do
      @index.send(
        :parse_enumerated_entry, "{",
        expected_kind: Hive::Attempts::DecisionIndex::ROUTING_DECISION
      )
    end

    2.times do |offset|
      @index.record_routing_decision(
        decision: selected_decision("decision-#{offset}"),
        task_generation: "generation-1", subject: subject.merge("task_id" => offset.to_s),
        project: "demo", attempt_id: "attempt-#{offset}"
      )
    end
    @index.define_singleton_method(:parse_enumerated_entry) do |_bytes, expected_kind:|
      raise "unexpected kind" unless expected_kind == Hive::Attempts::DecisionIndex::ROUTING_DECISION

      { "value" => { "decision" => { "decided_at" => Object.new, "decision_id" => "id" } } }
    end
    assert_raises(Hive::Attempts::StoreError) { @index.routing_decisions }
  end

  def test_routing_projection_schema_rejects_each_cross_field_invariant
    key = { "task_generation" => "generation-1", "subject" => subject }
    base = {
      "project" => "demo", "attempt_id" => "attempt-1",
      "decision" => selected_decision("decision-1").to_h
    }
    mutations = [
      ->(value) { value["future"] = true },
      ->(value) { value["decision"]["future"] = true },
      ->(value) { value["decision"]["task_generation"] = "other" },
      ->(value) { value["decision"]["policy_digest"] = "invalid" },
      ->(value) { value["decision"]["status"] = "unknown" },
      ->(value) { value["attempt_id"] = nil },
      ->(value) { value["decision"]["next_action_owner"] = "router" },
      ->(value) { value["decision"]["policy"]["future"] = true },
      ->(value) { value["decision"]["policy"]["pin"] = { "provider" => 1, "model" => nil } },
      ->(value) { value["decision"]["policy"]["pin"] = { "provider" => "account-a", "model" => 1 } },
      ->(value) { value["decision"]["policy"]["requirements"]["tools"] = "shell" },
      ->(value) { value["decision"]["selected_route"] = nil }
    ]

    mutations.each do |mutation|
      value = Marshal.load(Marshal.dump(base))
      mutation.call(value)
      assert_raises(Hive::Attempts::StoreError) do
        @index.send(:validate_routing_decision_value!, value, key: key)
      end
    end
  end

  private

  def selected_decision(id)
    Hive::ProviderRouting::Decision.selected(
      request: request,
      route: route,
      considered: [ route ],
      decision_id: id,
      decided_at: NOW
    )
  end

  def request
    @request ||= Hive::ProviderRouting::Request.new(
      policy: policy,
      task_generation: "generation-1"
    )
  end

  def policy
    @policy ||= Hive::ProviderRouting::Policy.explicit(
      stage: "execute",
      routes: [ route ],
      requirements: Hive::ProviderRouting::Requirements.empty,
      pin: nil,
      account_policy: {
        "account-a" => {
          "adapter" => "codex",
          "launch_binding" => "default",
          "models" => [ "model-a" ],
          "max_concurrent" => 1,
          "cooldown_sec" => Hive::ProviderRouting::DEFAULT_COOLDOWN_SEC
        }
      }
    )
  end

  def route
    @route ||= Hive::ProviderRouting::Route.new(
      id: "account-a/model-a",
      account: "account-a",
      adapter: "codex",
      launch_binding: "default",
      model: "model-a",
      effort: "high",
      order: 0,
      capabilities: {
        "context" => "large", "quality" => "high",
        "tools" => %w[shell], "permissions" => %w[read]
      }
    )
  end

  def subject
    {
      "kind" => "task_stage",
      "task_id" => "42",
      "task_slug" => "task",
      "intended_stage" => "4-execute"
    }
  end

  def all_bytes
    Dir.glob(File.join(@root, "**", "*.json")).map { |path| File.binread(path) }.join
  end
end
