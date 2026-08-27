require_relative "../../test_helper"
require "hive/attempts/capability"
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

  def test_daily_acceptances_expose_point_accounting_without_mutable_aliases
    record = Hive::Attempts::Record.new(current_attempt)
    @index.record_acceptance(record)

    acceptances = @index.daily_acceptances(date: NOW.to_date)
    assert_equal({
      "accepted_at" => record["accepted_at"],
      "project" => "demo",
      "refunded" => false
    }, acceptances.fetch("attempt-1"))
    assert_predicate acceptances, :frozen?
    assert_predicate acceptances.fetch("attempt-1"), :frozen?
  end

  def test_live_reservation_round_trips_bounded_patrol_admission_metadata
    admission = {
      "workflow" => "patrol_fix", "stage" => "2-fix",
      "runtime_digest" => "a" * 64, "utc_date" => NOW.to_date.iso8601
    }
    @index.reserve_live(
      attempt_id: "attempt-1", project: "demo", task_slug: "task",
      admission: admission
    )
    @index.confirm_live(
      attempt_id: "attempt-1", project: "demo", task_slug: "task",
      admission: admission
    )

    reservation = Hive::Attempts::DecisionIndex.new(root: @root)
      .live_reservations.fetch("attempt-1")
    assert_equal "active", reservation.fetch("phase")
    assert_equal admission, reservation.fetch("admission")
  end

  def test_failure_cohort_opens_durably_and_allows_only_one_probe
    identity = failure_cohort_identity
    3.times do |index|
      @index.record_failure_cohort(
        attempt_id: "failure-#{index}", identity: identity,
        occurred_at: NOW + index
      )
    end

    blocked = @index.failure_cohort_admission(
      identity: identity, date: NOW.to_date, now: NOW + 10
    )
    assert_equal "blocked", blocked.fetch("status")
    assert_equal "failure_cohort_cooldown", blocked.fetch("reason")

    restarted = Hive::Attempts::DecisionIndex.new(root: @root)
    probe = restarted.failure_cohort_admission(
      identity: identity, date: NOW.to_date,
      now: NOW + Hive::Attempts::DecisionIndex::FAILURE_COHORT_COOLDOWN_SEC + 10
    )
    assert_equal "probe", probe.fetch("status")
    assert restarted.claim_failure_cohort_probe(
      identity: identity, date: NOW.to_date,
      attempt_id: "probe-1", now: NOW + 4_000
    )
    refute restarted.claim_failure_cohort_probe(
      identity: identity, date: NOW.to_date,
      attempt_id: "probe-2", now: NOW + 4_000
    )
  end

  def test_explicit_release_bypasses_pacing_once_but_not_an_active_probe
    identity = failure_cohort_identity
    3.times do |index|
      @index.record_failure_cohort(
        attempt_id: "failure-#{index}", identity: identity,
        occurred_at: NOW + index
      )
    end

    release = @index.failure_cohort_admission(
      identity: identity, date: NOW.to_date, now: NOW + 10,
      explicit_release: true
    )
    assert_equal "probe", release.fetch("status")
    assert @index.claim_failure_cohort_probe(
      identity: identity, date: NOW.to_date,
      attempt_id: "probe-1", now: NOW + 10,
      explicit_release: true
    )
    assert_equal "blocked", @index.failure_cohort_admission(
      identity: identity, date: NOW.to_date, now: NOW + 11,
      explicit_release: true
    ).fetch("status")
  end

  def test_concurrent_probe_claims_admit_exactly_one_attempt
    skip "fork is unavailable" unless Process.respond_to?(:fork)

    identity = failure_cohort_identity
    3.times do |index|
      @index.record_failure_cohort(
        attempt_id: "failure-#{index}", identity: identity,
        occurred_at: NOW + index
      )
    end
    release_read, release_write = IO.pipe
    children = 2.times.map do |index|
      result_read, result_write = IO.pipe
      pid = fork do
        release_write.close
        result_read.close
        release_read.read(1)
        restarted = Hive::Attempts::DecisionIndex.new(root: @root)
        Marshal.dump(
          restarted.claim_failure_cohort_probe(
            identity: identity, date: NOW.to_date,
            attempt_id: "probe-#{index}", now: NOW + 4_000
          ),
          result_write
        )
      ensure
        result_write.close unless result_write.closed?
      end
      result_write.close
      [ pid, result_read ]
    end
    release_read.close
    release_write.write("11")
    release_write.close

    claims = children.map do |pid, reader|
      value = Marshal.load(reader)
      Process.wait(pid)
      reader.close
      value
    end
    assert_equal [ false, true ], claims.sort_by { |value| value ? 1 : 0 }
  end

  def test_failed_probe_reopens_the_same_cohort
    identity = failure_cohort_identity
    3.times do |index|
      @index.record_failure_cohort(
        attempt_id: "failure-#{index}", identity: identity,
        occurred_at: NOW + index
      )
    end
    @index.claim_failure_cohort_probe(
      identity: identity, date: NOW.to_date,
      attempt_id: "probe-1", now: NOW + 4_000
    )
    @index.record_failure_cohort(
      attempt_id: "probe-1", identity: identity,
      occurred_at: NOW + 4_010
    )

    result = Hive::Attempts::DecisionIndex.new(root: @root)
      .failure_cohort_admission(
        identity: identity, date: NOW.to_date, now: NOW + 4_011
      )
    assert_equal "blocked", result.fetch("status")
    assert_equal (NOW + 4_010 + 3_600).iso8601(6), result.fetch("retry_at")
  end

  def test_out_of_order_failure_cannot_shorten_an_open_cooldown
    identity = failure_cohort_identity
    [ 100, 200, 300 ].each_with_index do |offset, index|
      @index.record_failure_cohort(
        attempt_id: "failure-#{index}", identity: identity,
        occurred_at: NOW + offset
      )
    end
    @index.record_failure_cohort(
      attempt_id: "late-observed-old-failure", identity: identity,
      occurred_at: NOW + 50
    )

    result = @index.failure_cohort_admission(
      identity: identity, date: NOW.to_date, now: NOW + 400
    )
    assert_equal "blocked", result.fetch("status")
    assert_equal (NOW + 300 + 3_600).iso8601(6), result.fetch("retry_at")
  end

  def test_probe_with_a_different_code_preserves_the_original_cohort
    identity = failure_cohort_identity
    3.times do |index|
      @index.record_failure_cohort(
        attempt_id: "failure-#{index}", identity: identity,
        occurred_at: NOW + index
      )
    end
    @index.claim_failure_cohort_probe(
      identity: identity, date: NOW.to_date,
      attempt_id: "probe-1", now: NOW + 4_000
    )
    changed = identity.merge("code" => "provider_timeout")
    @index.record_failure_cohort(
      attempt_id: "probe-1", identity: changed,
      occurred_at: NOW + 4_010
    )

    original = @index.failure_cohort_admission(
      identity: identity, date: NOW.to_date, now: NOW + 4_011
    )
    assert_equal "blocked", original.fetch("status")
    assert_equal (NOW + 4_010 + 3_600).iso8601(6), original.fetch("retry_at")
    assert_equal "open", @index.failure_cohort_admission(
      identity: changed, date: NOW.to_date, now: NOW + 4_011
    ).fetch("status")
  end

  def test_unrelated_failure_does_not_clear_a_live_probe
    identity = failure_cohort_identity
    3.times do |index|
      @index.record_failure_cohort(
        attempt_id: "failure-#{index}", identity: identity,
        occurred_at: NOW + index
      )
    end
    @index.claim_failure_cohort_probe(
      identity: identity, date: NOW.to_date,
      attempt_id: "probe-1", now: NOW + 4_000
    )

    @index.record_failure_cohort(
      attempt_id: "concurrent-failure", identity: identity,
      occurred_at: NOW + 4_010
    )

    refute @index.claim_failure_cohort_probe(
      identity: identity, date: NOW.to_date,
      attempt_id: "probe-2", now: NOW + 4_011,
      explicit_release: true
    )
  end

  def test_successful_probe_closes_only_its_runtime_cohort_and_utc_rollover_releases
    identity = failure_cohort_identity
    3.times do |index|
      @index.record_failure_cohort(
        attempt_id: "failure-#{index}", identity: identity,
        occurred_at: NOW + index
      )
    end
    @index.claim_failure_cohort_probe(
      identity: identity, date: NOW.to_date,
      attempt_id: "probe-1", now: NOW + 4_000
    )
    @index.record_failure_cohort_success(
      attempt_id: "probe-1", date: NOW.to_date
    )

    assert_equal "open", @index.failure_cohort_admission(
      identity: identity, date: NOW.to_date, now: NOW + 4_001
    ).fetch("status")

    repaired = identity.merge("runtime_digest" => "b" * 64)
    assert_equal "open", @index.failure_cohort_admission(
      identity: repaired, date: NOW.to_date, now: NOW + 10
    ).fetch("status")
    assert_equal "open", @index.failure_cohort_admission(
      identity: identity, date: NOW.to_date + 1, now: NOW + 86_400
    ).fetch("status")
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

  def current_attempt
    Hive::Attempts::Record.launching(
      attempt_id: "attempt-1", request_id: "request-1",
      predecessor_attempt_id: nil,
      task_id: "42", project: "demo", task_slug: "task",
      intended_stage: "4-execute", task_generation: "generation-1",
      progress_token: "progress-1", provider: "codex",
      worker_argv: [ "hive", "run", "task" ],
      claim_capability_digest: Hive::Attempts::Capability.digest("c" * 64),
      starting_revision: nil, retry_charge: 0, inherited_outputs: [],
      launch_timeout_sec: 30, now: NOW
    ).to_h
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

  def failure_cohort_identity
    {
      "runtime_digest" => "a" * 64,
      "project" => "demo",
      "workflow" => "patrol_fix",
      "stage" => "2-fix",
      "code" => "agent_exit_nonzero"
    }
  end

  def all_bytes
    Dir.glob(File.join(@root, "**", "*.json")).map { |path| File.binread(path) }.join
  end
end
