require_relative "../../test_helper"
require "hive/refactor_patrol/architecture_intake_transitions"

class RefactorPatrolArchitectureIntakeTransitionsTest < Minitest::Test
  def test_enqueues_with_deterministic_direct_identities
    calls = []
    store = Object.new
    store.define_singleton_method(:enqueue_manifest!) do |manifest, **options|
      calls << [ manifest, options ]
      { "job_id" => manifest.fetch("job_id") }
    end
    manifest = { "job_id" => "job-1", "manifest_checksum" => "a" * 64 }
    now = Time.utc(2026, 8, 21)

    result = Hive::RefactorPatrol::ArchitectureIntakeTransitions.new.enqueue(
      entry: {}, store: store, manifest: manifest, policy: { "epoch" => 1 },
      now: now, dry_run: true
    )

    assert_equal({ "job_id" => "job-1" }, result)
    options = calls.fetch(0).fetch(1)
    assert_match(/\Aocc-[a-f0-9]{64}\z/, options.fetch(:occurrence_id))
    assert_match(/\Aintent-[a-f0-9]{64}\z/, options.fetch(:intake_transition_id))
    assert_equal now, options.fetch(:now)
    assert options.fetch(:dry_run)
  end

  def test_identity_changes_with_manifest_checksum
    store = Object.new
    ids = []
    store.define_singleton_method(:enqueue_manifest!) do |_manifest, **options|
      ids << options.fetch(:occurrence_id)
    end
    subject = Hive::RefactorPatrol::ArchitectureIntakeTransitions.new

    %w[a b].each do |checksum|
      subject.enqueue(
        entry: {}, store: store,
        manifest: { "job_id" => "job-1", "manifest_checksum" => checksum * 64 },
        policy: {}, now: Time.now
      )
    end

    refute_equal ids.fetch(0), ids.fetch(1)
  end
end
