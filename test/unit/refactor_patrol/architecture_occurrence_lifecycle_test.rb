require "test_helper"
require "hive/refactor_patrol/architecture_occurrence_lifecycle"

class RefactorPatrolArchitectureOccurrenceLifecycleTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 29, 12)

  def test_recovery_wraps_a_job_occurrence_mismatch_with_its_identifiers
    occurrence = reserved_occurrence("job-7")
    store = Object.new
    store.define_singleton_method(:each_recovery_active_occurrence) do |&block|
      block.call(occurrence)
    end
    store.define_singleton_method(:read_job) do |_job_id|
      { "occurrence_id" => "occ-#{'b' * 64}", "complete" => false }
    end

    error = assert_raises(Hive::RefactorPatrol::ArchitectureOccurrenceLifecycle::RecoveryError) do
      lifecycle.recover(store: store, entry: { "name" => "demo" }, now: NOW) { |job| job }
    end

    assert_equal occurrence.fetch("occurrence_id"), error.occurrence_id
    assert_equal "job-7", error.job_id
    assert_equal "architecture patrol recovery occurrence does not match its job", error.message
  end

  def test_recovery_re_raises_an_existing_recovery_error_without_masking_it
    original = Hive::RefactorPatrol::ArchitectureOccurrenceLifecycle::RecoveryError.new(
      error: RuntimeError.new("outbox unavailable"),
      occurrence_id: "occ-#{'c' * 64}", job_id: "job-7"
    )
    occurrence = reserved_occurrence("job-7")
    store = Object.new
    store.define_singleton_method(:each_recovery_active_occurrence) do |&block|
      block.call(occurrence)
    end
    store.define_singleton_method(:read_job) { |_job_id| raise original }

    error = assert_raises(
      Hive::RefactorPatrol::ArchitectureOccurrenceLifecycle::RecoveryError
    ) do
      lifecycle.recover(store: store, entry: { "name" => "demo" }, now: NOW) { |job| job }
    end
    assert_same original, error
  end

  def test_recovery_rejects_a_non_architecture_provisional_capture
    occurrence = mutable(reserved_occurrence("job-7"))
    occurrence.dig("provisional_capture", "reservation")["kind"] =
      "ordinary"
    store = Object.new
    store.define_singleton_method(:each_recovery_active_occurrence) do |&block|
      block.call(occurrence)
    end

    error = assert_raises(Hive::RefactorPatrol::ArchitectureOccurrenceLifecycle::RecoveryError) do
      lifecycle.recover(store: store, entry: { "name" => "demo" }, now: NOW) { |job| job }
    end

    assert_nil error.job_id
    assert_equal "patrol capture is malformed", error.message
  end

  def test_reservation_rejects_a_malformed_source_time_before_writing
    store = Object.new
    store.define_singleton_method(:occurrence_capture) { |_job_id| nil }
    store.define_singleton_method(:reserve_occurrence!) do |*|
      flunk("invalid source time must not reserve an occurrence")
    end

    error = assert_raises(Hive::ConfigError) do
      lifecycle.reserve(
        store: store, entry: { "project_id" => "project-1", "name" => "demo" },
        aggregate: {
          "job_id" => "job-7", "created_at" => "not-a-time",
          "source" => { "repository" => "owner/demo", "number" => 7,
                        "merge_sha" => "a" * 40, "manifest_checksum" => "b" * 64 }
        }, migration: { "owner" => "legacy", "epoch" => 1 }, now: NOW
      )
    end

    assert_equal "architecture patrol occurrence time is malformed", error.message
  end

  def test_recovery_reports_a_capture_without_the_job_binding
    occurrence = mutable(reserved_occurrence("job-7"))
    occurrence.dig("provisional_capture", "reservation").delete("job_id")
    store = Object.new
    store.define_singleton_method(:each_recovery_active_occurrence) do |&block|
      block.call(occurrence)
    end

    error = assert_raises(Hive::RefactorPatrol::ArchitectureOccurrenceLifecycle::RecoveryError) do
      lifecycle.recover(store: store, entry: { "name" => "demo" }, now: NOW) { |job| job }
    end

    assert_equal "patrol capture is malformed", error.message
  end

  def test_recovery_job_binding_defensively_rejects_wrong_kind_and_missing_id
    capture = Struct.new(:reservation)
    values = [
      [
        capture.new({ "kind" => "ordinary", "job_id" => "job-7" }),
        /not architecture work/
      ],
      [
        capture.new({ "kind" => "architecture" }),
        /missing "job_id"/
      ]
    ]

    values.each do |value, message|
      with_replaced_singleton_method(
        Hive::Modules::Migration::PatrolCapture,
        :from_h,
        ->(_payload) { value }
      ) do
        error = assert_raises(Hive::ConfigError) do
          lifecycle.send(
            :recovery_job_id,
            { "provisional_capture" => {} }
          )
        end
        assert_match message, error.message
      end
    end
  end

  def test_rollover_requires_a_current_reserved_occurrence
    store = Object.new
    store.define_singleton_method(:occurrence_for_job) { |_job_id| nil }

    error = assert_raises(Hive::ConfigError) do
      lifecycle.rollover(
        store: store,
        entry: { "name" => "demo" },
        aggregate: { "job_id" => "job-7" },
        now: NOW
      )
    end

    assert_equal "architecture patrol current occurrence cannot roll",
                 error.message
  end

  def test_pending_rollover_ignores_a_successor_for_an_unrelated_predecessor
    occurrence = reserved_occurrence("job-7", generation: 2)
    store = Object.new
    store.define_singleton_method(:read_job) do |_job_id|
      { "occurrence_id" => "occ-#{'f' * 64}" }
    end

    refute lifecycle.send(
      :recover_pending_rollovers,
      store,
      { "name" => "demo" },
      NOW,
      [ occurrence ]
    )
  end

  def test_pending_rollover_preserves_an_existing_recovery_error
    occurrence = reserved_occurrence("job-7", generation: 2)
    successor = Hive::Modules::Migration::PatrolCapture.from_h(
      occurrence.fetch("provisional_capture")
    )
    predecessor = lifecycle.send(:predecessor_capture, successor)
    original = Hive::RefactorPatrol::ArchitectureOccurrenceLifecycle::RecoveryError.new(
      error: RuntimeError.new("transition evidence unavailable"),
      occurrence_id: predecessor.occurrence_id,
      job_id: "job-7"
    )
    store = Object.new
    store.define_singleton_method(:read_job) do |_job_id|
      { "occurrence_id" => predecessor.occurrence_id }
    end
    store.define_singleton_method(:assert_recorded_transitions_terminal!) do |_aggregate|
      raise original
    end

    error = assert_raises(
      Hive::RefactorPatrol::ArchitectureOccurrenceLifecycle::RecoveryError
    ) do
      lifecycle.send(
        :recover_pending_rollovers,
        store,
        { "name" => "demo" },
        NOW,
        [ occurrence ]
      )
    end

    assert_same original, error
  end

  def test_pending_rollover_retires_abandoned_prepared_effects_before_finalization
    occurrence = reserved_occurrence("job-7", generation: 2)
    successor = Hive::Modules::Migration::PatrolCapture.from_h(
      occurrence.fetch("provisional_capture")
    )
    predecessor = lifecycle.send(:predecessor_capture, successor)
    aggregate = {
      "job_id" => "job-7",
      "occurrence_id" => predecessor.occurrence_id,
      "state" => "blocked",
      "actions" => []
    }
    predecessor_occurrence = reserved_occurrence("job-7", generation: 1)
    calls = []
    store = Object.new
    store.define_singleton_method(:read_job) { |_job_id| aggregate }
    store.define_singleton_method(:assert_recorded_transitions_terminal!) do |_job|
      calls << :assert_terminal
    end
    store.define_singleton_method(
      :deny_unrecorded_prepared_effects_for_rollover!
    ) do |_job, occurrence_id:, now:|
      calls << [ :deny_abandoned, occurrence_id, now ]
    end
    store.define_singleton_method(:occurrence) do |occurrence_id|
      calls << :fetch_predecessor
      occurrence_id == predecessor.occurrence_id ?
        predecessor_occurrence : nil
    end
    store.define_singleton_method(:terminal_effect_receipt_ids) { |_id| [] }
    store.define_singleton_method(:finalize_occurrence!) do |**|
      calls << :finalize
    end
    store.define_singleton_method(:drain_occurrence_outbox!) do |*args, **|
      calls << [ :drain, args.first ]
    end
    store.define_singleton_method(:occurrence_terminalized?) { |_capture| true }
    store.define_singleton_method(:rollover_occurrence!) do |job_id, from:, to:, now:|
      calls << [ :rollover, job_id, from, to, now ]
    end

    assert lifecycle.send(
      :recover_pending_rollovers,
      store,
      { "name" => "demo" },
      NOW,
      [ occurrence ]
    )
    assert_equal [ :deny_abandoned, predecessor.occurrence_id, NOW ],
                 calls.fetch(1)
    assert_operator calls.index(:finalize), :>, calls.index(calls.fetch(1))
    assert_equal [
      :rollover, "job-7", predecessor.occurrence_id,
      successor.occurrence_id, NOW
    ], calls.last
  end

  def test_segment_generation_guards_reject_missing_or_malformed_values
    capture = Struct.new(:reservation)

    successor_error = assert_raises(Hive::ConfigError) do
      lifecycle.send(:successor_capture, capture.new({}), now: NOW)
    end
    assert_match(/generation is missing/, successor_error.message)

    predecessor_error = assert_raises(Hive::ConfigError) do
      lifecycle.send(:predecessor_capture, capture.new({}))
    end
    assert_match(/generation is missing/, predecessor_error.message)

    malformed = assert_raises(Hive::ConfigError) do
      lifecycle.send(
        :predecessor_capture,
        capture.new({ "attempt_generation" => 1 })
      )
    end
    assert_match(/successor generation is malformed/, malformed.message)
  end

  def test_rollover_finalization_records_action_outcomes_and_requires_terminal_state
    occurrence = reserved_occurrence("job-7", generation: 1)
    provisional = Hive::Modules::Migration::PatrolCapture.from_h(
      occurrence.fetch("provisional_capture")
    )
    finalized = nil
    store = Object.new
    store.define_singleton_method(:occurrence) { |_occurrence_id| occurrence }
    store.define_singleton_method(:terminal_effect_receipt_ids) { |_occurrence_id| [] }
    store.define_singleton_method(:finalize_occurrence!) do |capture:, **|
      finalized = capture
    end
    store.define_singleton_method(:drain_occurrence_outbox!) { |*| true }
    store.define_singleton_method(:occurrence_terminalized?) { |_capture| true }
    aggregate = {
      "job_id" => "job-7",
      "state" => "acting",
      "actions" => [
        { "canonical_action_id" => "action-1", "outcome" => "retry" }
      ]
    }

    lifecycle.send(
      :finalize_rollover_segment,
      store,
      { "name" => "demo" },
      provisional,
      aggregate,
      NOW
    )

    assert_equal({ "action-1" => "retry" },
                 finalized.outcome.fetch("action_outcomes"))

    missing = Object.new
    missing.define_singleton_method(:occurrence) { |_occurrence_id| nil }
    missing.define_singleton_method(:occurrence_terminalized?) { |_capture| false }
    error = assert_raises(Hive::ConfigError) do
      lifecycle.send(
        :finalize_rollover_segment,
        missing,
        { "name" => "demo" },
        provisional,
        aggregate,
        NOW
      )
    end
    assert_match(/predecessor occurrence is not terminal/, error.message)
  end

  private

  def lifecycle
    Hive::RefactorPatrol::ArchitectureOccurrenceLifecycle.new(
      migration_authority: :legacy, dry_run: false,
      evidence_store_factory: ->(*) { Object.new }, event_publisher: Object.new,
      module_schedule: "* * * * *", reservation_error: RuntimeError
    )
  end

  def reserved_occurrence(job_id, generation: nil)
    reservation = {
      "kind" => "architecture",
      "id" => job_id,
      "job_id" => job_id
    }
    if generation
      reservation["attempt_generation"] = generation
      reservation["window_started_at"] = NOW.iso8601(6)
    end
    capture = Hive::Modules::Migration::PatrolCapture.build(
      module_name: "architecture-patrol",
      project: { "project_id" => "project-1", "name" => "demo", "repository" => "owner/demo" },
      trigger: {
        "kind" => "pull_request.merged",
        "id" => "owner/demo:7:#{'a' * 40}",
        "manifest_digest" => "b" * 64,
        "merge_sha" => "a" * 40
      },
      reservation: reservation,
      owner: "legacy", owner_epoch: 1,
      selection_input: { "kind" => "candidate", "job_id" => job_id, "phase" => "discovery" },
      selection: Hive::Modules::Migration::PatrolDecisionProjection.build(
        module_name: "architecture-patrol", rationale: "due", job_id: job_id,
        phase: "discovery"
      ), outcome_class: nil, outcome: nil,
      occurred_at: NOW, recorded_at: NOW
    )
    {
      "occurrence_id" => capture.occurrence_id,
      "phase" => "reserved",
      "provisional_capture" => capture.to_h,
      "outbox" => []
    }
  end

  def mutable(value)
    JSON.parse(JSON.generate(value))
  end
end
