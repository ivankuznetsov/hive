require "test_helper"
require "hive/refactor_patrol/job_occurrence_lifecycle"

class HiveRefactorPatrolJobOccurrenceLifecycleTest < Minitest::Test
  class Occurrences
    attr_reader :calls
    attr_accessor :effect_state_value, :snapshot_state,
                  :attempt_generation

    def initialize
      @calls = []
      @effect_state_value = nil
      @snapshot_state = "prepared"
      @attempt_generation = 1
    end

    def reserve_manifest!(*args, **options)
      record(:reserve_manifest!, args, options)
    end

    def recovery_backoff(now:)
      record(:recovery_backoff, [], { now: now })
      { "blocked" => false }
    end

    def rebuild_recovery_index!
      record(:rebuild_recovery_index!, [], {})
    end

    def with_effect_sender_lock(intent)
      record(:with_effect_sender_lock, [ intent ], {})
      yield
    end

    def drain_outbox!(*args, **options)
      record(:drain_outbox!, args, options)
      true
    end

    def effect_intent(occurrence_id, intent_id)
      record(:effect_intent, [ occurrence_id, intent_id ], {})
      { "occurrence_id" => occurrence_id, "intent_id" => intent_id }
    end

    def fetch(occurrence_id)
      record(:fetch, [ occurrence_id ], {})
      {
        "provisional_capture" => {
          "reservation" => {
            "attempt_generation" => attempt_generation
          }
        },
        "effects" => (
          attempt_generation == 1 ?
            { "intake-7" => {}, "remote-7" => {} } :
            { "current-8" => {} }
        )
      }
    end

    def effect_state(intent)
      record(:effect_state, [ intent ], {})
      effect_state_value
    end

    def effect_recovery_snapshot(occurrence_id, intent_ids:)
      record(
        :effect_recovery_snapshot, [ occurrence_id ],
        { intent_ids: intent_ids }
      )
      intent_ids.to_h do |intent_id|
        [
          intent_id,
          {
            "semantic" => { "intent_id" => intent_id },
            "state" => snapshot_state
          }
        ]
      end
    end

    private

    def record(name, args, options)
      calls << [ name, args, options ]
      name
    end
  end

  class Validator
    attr_reader :calls

    def initialize = @calls = []

    def validate_transition_semantic!(transition, semantic:, path:)
      calls << [ transition, semantic, path ]
      true
    end
  end

  def test_forwards_occurrence_effect_and_recovery_operations_to_the_journal_adapter
    occurrences = Occurrences.new
    lifecycle = build_lifecycle(occurrences: occurrences)

    assert_equal :reserve_manifest!, lifecycle.reserve_manifest_occurrence!(
      { "job_id" => "job-7" }, capture: :capture, now: Time.utc(2026, 7, 29)
    )
    assert_equal({ "blocked" => false }, lifecycle.recovery_backoff(now: Time.utc(2026, 7, 29)))
    assert_equal :rebuild_recovery_index!,
                 lifecycle.rebuild_recovery_index!
    assert_equal :sent, lifecycle.with_effect_sender_lock(:intent) { :sent }
    assert lifecycle.drain_occurrence_outbox!(
      "occ-7", evidence_store: :evidence, project_entry: { "name" => "demo" }
    )

    assert_equal(
      %i[
        reserve_manifest! recovery_backoff rebuild_recovery_index!
        with_effect_sender_lock drain_outbox!
      ],
      occurrences.calls.map(&:first)
    )
  end

  def test_collects_and_validates_unsettled_recorded_transitions
    occurrences = Occurrences.new
    validator = Validator.new
    aggregate = aggregate_with_transition
    lifecycle = build_lifecycle(
      occurrences: occurrences,
      validator: validator,
      aggregate_reader: ->(_job) { aggregate }
    )

    assert_equal %w[intake-7 remote-7],
                 lifecycle.recorded_effect_transitions("job-7").map { |item| item.fetch("intent_id") }
    unsettled = lifecycle.unsettled_recorded_transitions("job-7")

    assert_equal %w[intake-7 remote-7], unsettled.map { |intent, _| intent.fetch("intent_id") }
    assert_equal 1, validator.calls.size
    assert_equal "/jobs/job-7.json", validator.calls.first.fetch(2)
  end

  def test_terminal_transition_recovery_uses_one_occurrence_snapshot
    occurrences = Occurrences.new
    occurrences.snapshot_state = "committed"
    lifecycle = build_lifecycle(occurrences: occurrences)

    assert_empty lifecycle.unsettled_recorded_transitions("job-7")
    calls = occurrences.calls.map(&:first).reject do |name|
      name == :fetch
    end
    assert_equal [ :effect_recovery_snapshot ], calls
    snapshot_call = occurrences.calls.find do |name, _args, _options|
      name == :effect_recovery_snapshot
    end
    assert_equal %w[intake-7 remote-7],
                 snapshot_call.dig(2, :intent_ids)
  end

  def test_rollover_recovers_only_transitions_from_the_current_occurrence
    occurrences = Occurrences.new
    occurrences.attempt_generation = 2
    aggregate = aggregate_with_transition.merge(
      "occurrence_id" => "occ-8",
      "attempts" => [
        {
          "occurrence_id" => "occ-7",
          "transitions" => [ transition("old-7") ]
        },
        {
          "occurrence_id" => "occ-8",
          "transitions" => [ transition("current-8") ]
        }
      ]
    )
    lifecycle = build_lifecycle(
      occurrences: occurrences,
      aggregate_reader: ->(_job) { aggregate }
    )

    unsettled = lifecycle.unsettled_recorded_transitions("job-7")

    assert_equal [ "current-8" ],
                 unsettled.map { |intent, _record| intent.fetch("intent_id") }
    snapshot_call = occurrences.calls.find do |name, _args, _options|
      name == :effect_recovery_snapshot
    end
    assert_equal [ "current-8" ],
                 snapshot_call.dig(2, :intent_ids)
  end

  def test_rejects_conflicting_transition_identity
    aggregate = aggregate_with_transition.merge(
      "actions" => [ { "transitions" => [
        { "intent_id" => "remote-7", "outcome" => "rejected", "error_code" => "conflict" }
      ] } ]
    )
    lifecycle = build_lifecycle(aggregate_reader: ->(_job) { aggregate })

    error = assert_raises(StandardError) do
      lifecycle.recorded_effect_transitions("job-7")
    end

    assert_match(/transition identity conflicts/, error.message)
  end

  def test_terminal_assertion_rejects_an_unsettled_recorded_transition
    lifecycle = build_lifecycle

    error = assert_raises(StandardError) do
      lifecycle.assert_recorded_transitions_terminal!("job-7")
    end

    assert_match(/prior recorded transitions are not terminal/, error.message)
  end

  def test_legacy_transition_without_digest_must_be_the_intake_transition
    aggregate = aggregate_with_transition
    aggregate.fetch("attempts").first.fetch("transitions").first
      .delete("semantic_digest")
    lifecycle = build_lifecycle(
      aggregate_reader: ->(_job) { aggregate }
    )

    error = assert_raises(StandardError) do
      lifecycle.unsettled_recorded_transitions("job-7")
    end

    assert_match(/no exact semantic digest/, error.message)
  end

  private

  def build_lifecycle(occurrences: Occurrences.new, validator: Validator.new,
                      aggregate_reader: ->(_job) { aggregate_with_transition })
    Hive::RefactorPatrol::JobOccurrenceLifecycle.new(
      inconsistent_record: StandardError,
      record_validator: validator,
      aggregate_reader: aggregate_reader,
      job_path: ->(job_id) { "/jobs/#{job_id}.json" },
      architecture_occurrences: occurrences
    )
  end

  def aggregate_with_transition
    {
      "job_id" => "job-7",
      "occurrence_id" => "occ-7",
      "intake_transition_id" => "intake-7",
      "attempts" => [ { "occurrence_id" => "occ-7", "transitions" => [
        {
          "intent_id" => "remote-7",
          "outcome" => "applied",
          "error_code" => nil,
          "semantic_digest" => "a" * 64
        }
      ] } ],
      "actions" => []
    }
  end

  def transition(intent_id)
    {
      "intent_id" => intent_id,
      "outcome" => "applied",
      "error_code" => nil,
      "semantic_digest" => "a" * 64
    }
  end
end
