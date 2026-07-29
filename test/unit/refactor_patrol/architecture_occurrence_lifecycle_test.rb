require "test_helper"
require "hive/refactor_patrol/architecture_occurrence_lifecycle"

class RefactorPatrolArchitectureOccurrenceLifecycleTest < Minitest::Test
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

  private

  def lifecycle
    Hive::RefactorPatrol::ArchitectureOccurrenceLifecycle.new(
      migration_authority: :legacy, dry_run: false,
      evidence_store_factory: ->(*) { Object.new }, event_publisher: Object.new,
      module_schedule: "* * * * *", reservation_error: RuntimeError
    )
  end

  def reserved_occurrence(job_id)
    reservation = {
      "kind" => "architecture",
      "id" => job_id,
      "job_id" => job_id
    }
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
