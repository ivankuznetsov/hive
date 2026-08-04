require "test_helper"
require "hive/refactor_patrol/architecture_occurrence_store"

class RefactorPatrolArchitectureOccurrenceStoreTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 28, 15)
  CorruptRecord = Class.new(StandardError)
  InconsistentRecord = Class.new(StandardError)

  class Journal
    METHODS = %i[
      prepare_effect! effect_state effect_intent mark_dispatch_uncertain!
      reset_effect_prepared! settle_effect! deny_effect! receipt
      effect_receipt_ids finalize!
    ].freeze

    attr_accessor :record, :outbox, :failure
    attr_reader :calls

    def initialize
      @calls = []
      @outbox = []
    end

    def reserve!(capture, **options)
      fail_if!(:reserve!)
      calls << [ :reserve!, capture, options ]
      self.record = {
        "occurrence_id" => capture.occurrence_id,
        "provisional_capture" => capture.to_h
      }
    end

    def fetch(occurrence_id)
      fail_if!(:fetch)
      calls << [ :fetch, occurrence_id ]
      record
    end

    def each_recovery_active
      return enum_for(__method__) unless block_given?

      fail_if!(:each_recovery_active)
      calls << [ :each_recovery_active ]
      [ record ].compact.each { |value| yield value }
    end

    def pending_outbox(occurrence_id)
      fail_if!(:pending_outbox)
      calls << [ :pending_outbox, occurrence_id ]
      outbox
    end

    def rebuild_recovery_index!
      fail_if!(:rebuild_recovery_index!)
      calls << [ :rebuild_recovery_index! ]
      { "occurrence_ids" => [] }
    end

    def record_recovery_failure!(**options)
      fail_if!(:record_recovery_failure!)
      calls << [ :record_recovery_failure!, options ]
      { "next_eligible_at" => NOW.iso8601 }
    end

    def clear_recovery_failure!(**options)
      fail_if!(:clear_recovery_failure!)
      calls << [ :clear_recovery_failure!, options ]
      true
    end

    def acknowledge_outbox!(occurrence_id, **options)
      fail_if!(:acknowledge_outbox!)
      calls << [ :acknowledge_outbox!, occurrence_id, options ]
      true
    end

    def with_effect_sender_lock(intent)
      fail_if!(:with_effect_sender_lock)
      calls << [ :with_effect_sender_lock, intent ]
      yield
    end

    METHODS.each do |method_name|
      define_method(method_name) do |*arguments, **options|
        fail_if!(method_name)
        calls << [ method_name, arguments, options ]
        method_name
      end
    end

    private

    def fail_if!(method_name)
      raise Hive::ConfigError, "#{method_name} failed" if failure == method_name
    end
  end

  class Evidence
    attr_reader :captures, :receipts

    def initialize
      @captures = []
      @receipts = []
    end

    def append_capture(value)
      captures << value
    end

    def append_receipt(value)
      receipts << value
    end
  end

  class Publisher
    attr_reader :calls

    def initialize
      @calls = []
    end

    def publish_prepared(entry, event)
      calls << [ entry, event ]
    end
  end

  def test_facade_reserves_job_owned_occurrence_and_delegates_effect_protocol
    journal = Journal.new
    store = occurrence_store(journal: journal)

    assert_equal capture.occurrence_id,
                 store.reserve_manifest!(
                   manifest, capture: capture.to_h, now: NOW
                 ).fetch("occurrence_id")
    assert_equal capture.occurrence_id,
                 store.reserve!(
                   "job-7", capture: capture, now: NOW
                 ).fetch("occurrence_id")
    assert_equal capture.occurrence_id,
                 store.capture_for_job("job-7").occurrence_id
    assert_equal [ capture.occurrence_id ],
                 store.each_recovery_active.map {
                   |row| row.fetch("occurrence_id")
                 }
    assert_empty store.rebuild_recovery_index!.fetch(
      "occurrence_ids"
    )

    assert_equal :prepare_effect!,
                 store.prepare_effect!(intent.to_h, now: NOW)
    assert_equal :effect_state, store.effect_state(intent)
    assert_equal :effect_intent,
                 store.effect_intent(
                   capture.occurrence_id, intent.intent_id
                 )
    assert_equal :locked,
                 store.with_effect_sender_lock(intent) { :locked }
    assert_equal :mark_dispatch_uncertain!,
                 store.mark_dispatch_uncertain!(
                   intent, now: NOW
                 )
    assert_equal :reset_effect_prepared!,
                 store.reset_effect_prepared!(
                   intent, now: NOW
                 )
    assert_equal :settle_effect!,
                 store.settle_effect!(
                   intent, status: "committed", outcome: {}, now: NOW
                 )
    assert_equal :deny_effect!,
                 store.deny_effect!(
                   intent, outcome: {}, now: NOW
                 )
    assert_equal :receipt,
                 store.effect_receipt(
                   receipt.receipt_id,
                   occurrence_id: capture.occurrence_id
                 )
    assert_equal :effect_receipt_ids,
                 store.terminal_effect_receipt_ids(capture.occurrence_id)
    assert_equal :finalize!,
                 store.finalize!(
                   capture: capture, event: { "event_id" => "event-1" },
                   now: NOW
                 )
  end

  def test_manifest_repository_target_binds_the_pr_url_host_and_slug
    assert_equal "github.com/owner/demo",
                 Hive::RefactorPatrol::PrManifest.repository_target(
                   manifest.fetch("source")
                 )
    urls = [
      "https://github.com/other/demo/pull/7",
      "https://%",
      "mailto:user@example.com",
      "urn:foo"
    ]
    urls.each do |url|
      source = manifest.fetch("source").merge("url" => url)
      assert_raises(Hive::RefactorPatrol::PrManifest::Invalid) do
        Hive::RefactorPatrol::PrManifest.repository_target(source)
      end
    end
  end

  def test_pre_target_repository_capture_is_admitted_only_for_exact_replay
    legacy = capture_for(
      manifest,
      project: capture.project.merge("repository" => "owner/demo")
    )
    fresh = occurrence_store(journal: Journal.new)
    assert_raises(InconsistentRecord) do
      fresh.reserve_manifest!(manifest, capture: legacy, now: NOW)
    end

    journal = Journal.new
    journal.record = {
      "occurrence_id" => legacy.occurrence_id,
      "provisional_capture" => legacy.to_h
    }
    replay = occurrence_store(
      journal: journal,
      job_reader: ->(_job_id) {
        job.merge("occurrence_id" => legacy.occurrence_id)
      }
    )
    assert_equal legacy.occurrence_id,
                 replay.reserve_manifest!(
                   manifest, capture: legacy, now: NOW
                 ).fetch("occurrence_id")
    assert_equal legacy.occurrence_id,
                 replay.reserve!(
                   "job-7", capture: legacy, now: NOW
                 ).fetch("occurrence_id")

    corrupt_journal = Journal.new
    corrupt_journal.failure = :fetch
    assert_raises(InconsistentRecord) do
      occurrence_store(journal: corrupt_journal).reserve_manifest!(
        manifest, capture: legacy, now: NOW
      )
    end
  end

  def test_rebuild_recovery_index_translates_journal_corruption
    journal = Journal.new
    journal.failure = :rebuild_recovery_index!

    error = assert_raises(CorruptRecord) do
      occurrence_store(journal: journal).rebuild_recovery_index!
    end

    assert_match(/rebuild_recovery_index! failed/, error.message)
  end

  def test_job_pointer_conflicts_and_product_scope_mismatches_fail_closed
    journal = Journal.new
    store = occurrence_store(journal: journal)
    store.reserve!("job-7", capture: capture, now: NOW)

    conflicting = occurrence_store(
      journal: journal,
      job_reader: ->(_job_id) {
        job.merge("occurrence_id" => "occ-#{'f' * 64}")
      }
    )
    assert_raises(InconsistentRecord) do
      conflicting.reserve!("job-7", capture: capture, now: NOW)
    end

    mismatched_manifest = manifest.merge(
      "source" => manifest.fetch("source").merge(
        "repository" => "other/demo"
      )
    )
    mismatched_manifest = checksum_manifest(mismatched_manifest)
    assert_raises(InconsistentRecord) do
      store.reserve_manifest!(
        mismatched_manifest, capture: capture, now: NOW
      )
    end
    assert_raises(InconsistentRecord) do
      store.reserve_manifest!({}, capture: capture, now: NOW)
    end

    malformed_source = occurrence_store(
      journal: journal,
      job_reader: ->(_job_id) {
        job.merge(
          "occurrence_id" => capture.occurrence_id,
          "source" => { "registration" => "demo" }
        )
      }
    )
    assert_raises(InconsistentRecord) do
      malformed_source.reserve!("job-7", capture: capture, now: NOW)
    end

    assert_raises(InconsistentRecord) do
      store.reserve!(
        "job-7",
        capture: capture_for(
          manifest,
          project: capture.project.merge("name" => "other")
        ),
        now: NOW
      )
    end
    assert_raises(InconsistentRecord) do
      store.reserve!("job-7", capture: capture_for(manifest, module_name: "patrol"))
    end
    assert_raises(InconsistentRecord) do
      store.reserve!("job-7", capture: { "bad" => "capture" })
    end
    assert_raises(InconsistentRecord) do
      store.prepare_effect!(intent_for(scope: {}), now: NOW)
    end
    assert_raises(InconsistentRecord) do
      store.prepare_effect!(
        intent_for(occurrence_id: "occ-#{'f' * 64}"),
        now: NOW
      )
    end
    assert_raises(InconsistentRecord) do
      store.prepare_effect!(
        intent_for(
          scope: {
            "job_id" => "job-7",
            "canonical_action_id" => "missing"
          }
        ),
        now: NOW
      )
    end

    action_store = occurrence_store(
      journal: journal,
      job_reader: ->(_job_id) {
        job.merge(
          "actions" => [
            { "canonical_action_id" => "action-1" }
          ]
        )
      }
    )
    assert_equal :prepare_effect!,
                 action_store.prepare_effect!(
                   intent_for(
                     scope: {
                       "job_id" => "job-7",
                       "canonical_action_id" => "action-1"
                     }
                   ),
                   now: NOW
                 )
    assert_raises(InconsistentRecord) do
      store.effect_state(intent_for(module_name: "patrol"))
    end
    assert_raises(InconsistentRecord) do
      store.effect_state("not" => "an intent")
    end
    assert_raises(CorruptRecord) do
      store.reserve_manifest!(
        { "bad" => Float::NAN }, capture: capture, now: NOW
      )
    end
  end

  def test_outbox_projects_exact_types_and_refuses_ambiguous_entries
    journal = Journal.new
    journal.record = {
      "occurrence_id" => capture.occurrence_id,
      "provisional_capture" => capture.to_h
    }
    evidence = Evidence.new
    publisher = Publisher.new
    store = occurrence_store(journal: journal)
    journal.outbox = [
      outbox("receipt", receipt.receipt_id, receipt.to_h),
      outbox("capture", capture.capture_id, capture.to_h),
      outbox("event", "event-1", { "event_id" => "event-1" })
    ]

    assert store.drain_outbox!(
      capture.occurrence_id,
      evidence_store: evidence,
      event_publisher: publisher,
      project_entry: { "name" => "demo" }
    )
    assert_equal [ receipt.receipt_id ],
                 evidence.receipts.map(&:receipt_id)
    assert_equal [ capture.capture_id ],
                 evidence.captures.map(&:capture_id)
    assert_equal "event-1", publisher.calls.dig(0, 1, "event_id")

    journal.outbox = [ outbox("unknown", "bad", {}) ]
    assert store.drain_outbox!(
      capture.occurrence_id,
      evidence_store: evidence,
      kinds: [ "capture" ]
    )
    assert_raises(CorruptRecord) do
      store.drain_outbox!(
        capture.occurrence_id,
        evidence_store: evidence
      )
    end

    journal.outbox = [
      outbox("event", "event-2", { "event_id" => "event-2" })
    ]
    assert_raises(InconsistentRecord) do
      store.drain_outbox!(
        capture.occurrence_id,
        evidence_store: evidence
      )
    end

    journal.outbox = [
      {
        "kind" => "capture",
        "id" => "bad",
        "digest" => "bad",
        "bytes" => "{"
      }
    ]
    assert_raises(CorruptRecord) do
      store.drain_outbox!(
        capture.occurrence_id,
        evidence_store: evidence
      )
    end
  end

  def test_shared_config_errors_are_translated_at_every_product_port
    journal = Journal.new
    journal.record = {
      "occurrence_id" => capture.occurrence_id,
      "provisional_capture" => capture.to_h
    }
    store = occurrence_store(journal: journal)

    inconsistent_calls = {
      reserve!: -> { store.reserve!("job-7", capture: capture) },
      prepare_effect!: -> { store.prepare_effect!(intent) },
      effect_state: -> { store.effect_state(intent) },
      with_effect_sender_lock: -> {
        store.with_effect_sender_lock(intent) { :locked }
      },
      mark_dispatch_uncertain!: -> {
        store.mark_dispatch_uncertain!(intent)
      },
      reset_effect_prepared!: -> {
        store.reset_effect_prepared!(intent)
      },
      settle_effect!: -> {
        store.settle_effect!(
          intent, status: "committed", outcome: {}
        )
      },
      deny_effect!: -> {
        store.deny_effect!(intent, outcome: {})
      },
      finalize!: -> {
        store.finalize!(capture: capture, event: { "event_id" => "one" })
      }
    }
    inconsistent_calls.each do |journal_method, operation|
      journal.failure = journal_method
      assert_raises(InconsistentRecord, journal_method.to_s, &operation)
    end

    {
      fetch: -> { store.fetch_for_job("job-7") },
      receipt: -> {
        store.effect_receipt(
          receipt.receipt_id,
          occurrence_id: capture.occurrence_id
        )
      },
      effect_receipt_ids: -> {
        store.terminal_effect_receipt_ids(capture.occurrence_id)
      },
      pending_outbox: -> {
        store.drain_outbox!(
          capture.occurrence_id,
          evidence_store: Evidence.new
        )
      }
    }.each do |journal_method, operation|
      journal.failure = journal_method
      assert_raises(CorruptRecord, journal_method.to_s, &operation)
    end
  end

  def test_sender_lock_does_not_reclassify_a_downstream_config_error
    journal = Journal.new
    store = occurrence_store(journal: journal)
    error = Hive::ConfigError.new("downstream failed")

    observed = assert_raises(Hive::ConfigError) do
      store.with_effect_sender_lock(intent) { raise error }
    end

    assert_same error, observed
  end

  def test_recovery_failure_ports_keep_corruption_distinct_from_effect_state
    journal = Journal.new
    store = occurrence_store(journal: journal)

    journal.failure = :record_recovery_failure!
    assert_raises(CorruptRecord) do
      store.record_recovery_failure!(
        operation: "architecture_occurrence", occurrence_id: capture.occurrence_id,
        job_id: "job-7", error: RuntimeError.new("interrupted"), now: NOW
      )
    end

    journal.failure = :clear_recovery_failure!
    assert_raises(CorruptRecord) do
      store.clear_recovery_failure!(expected_generation: 3)
    end

    journal.failure = :effect_state
    assert_raises(InconsistentRecord) { store.effect_state(intent) }

    journal.failure = :effect_intent
    assert_raises(CorruptRecord) do
      store.effect_intent(capture.occurrence_id, intent.intent_id)
    end
  end

  private

  def occurrence_store(journal:, job_reader: ->(_job_id) { job })
    Hive::RefactorPatrol::ArchitectureOccurrenceStore.new(
      root: "/unused",
      job_reader: job_reader,
      id_validator: lambda do |job_id|
        raise CorruptRecord, "bad id" unless job_id == "job-7"

        job_id
      end,
      corrupt_record: CorruptRecord,
      inconsistent_record: InconsistentRecord,
      journal: journal
    )
  end

  def manifest
    @manifest ||= Hive::RefactorPatrol::PrManifest.build(
      source: {
        "url" => "https://github.com/owner/demo/pull/7",
        "number" => 7,
        "repository" => "owner/demo",
        "registration" => "demo",
        "base_branch" => "main",
        "base_sha" => "a" * 40,
        "merge_sha" => "b" * 40,
        "merged_at" => NOW.iso8601
      },
      files: [
        { "path" => "lib/demo.rb", "status" => "modified" }
      ]
    ).merge("job_id" => "job-7").then do |value|
      checksum_manifest(value)
    end
  end

  def checksum_manifest(value)
    payload = value.reject { |key, _item| key == "manifest_checksum" }
    value.merge(
      "manifest_checksum" =>
        Hive::RefactorPatrol::PrManifest.checksum(payload)
    )
  end

  def capture
    @capture ||= capture_for(manifest)
  end

  def capture_for(value, module_name: "architecture-patrol",
                  project: nil, reservation: nil)
    source = value.fetch("source")
    architecture = module_name == "architecture-patrol"
    selection_input = if architecture
      {
        "kind" => "candidate",
        "job_id" => value.fetch("job_id"),
        "phase" => "action"
      }
    else
      {
        "kind" => "operation",
        "operation" => "architecture-store-test"
      }
    end
    projection_attributes = {
      module_name: module_name,
      rationale: "due"
    }
    if architecture
      projection_attributes.merge!(
        job_id: value.fetch("job_id"),
        phase: "action"
      )
    end
    Hive::Modules::Migration::PatrolCapture.build(
      module_name: module_name,
      project: project || {
        "project_id" => "project-1",
        "name" => source.fetch("registration"),
        "repository" =>
          Hive::RefactorPatrol::PrManifest.repository_target(source)
      },
      trigger: {
        "kind" => "pull_request.merged",
        "id" => "owner/demo#7",
        "manifest_digest" => value.fetch("manifest_checksum"),
        "merge_sha" => source.fetch("merge_sha")
      },
      reservation: reservation || {
        "kind" => "architecture",
        "id" => value.fetch("job_id"),
        "job_id" => value.fetch("job_id")
      },
      owner: "legacy",
      owner_epoch: 1,
      selection_input: selection_input,
      selection:
        Hive::Modules::Migration::PatrolDecisionProjection.build(
          **projection_attributes
        ),
      outcome_class: "completed",
      outcome:
        architecture ?
          {
            "rationale" => "complete",
            "job_id" => value.fetch("job_id")
          } :
          {
            "rationale" => "complete"
          },
      occurred_at: NOW,
      recorded_at: NOW
    )
  end

  def intent
    @intent ||= intent_for
  end

  def intent_for(module_name: "architecture-patrol",
                 occurrence_id: capture.occurrence_id,
                 scope: { "job_id" => "job-7" })
    Hive::Modules::Migration::EffectIntent.build(
      module_name: module_name,
      occurrence_id: occurrence_id,
      authority: "legacy",
      owner_epoch: 1,
      sink: "issue",
      target: "owner/demo:issue",
      idempotency_key: "job-7:issue",
      capability: "github_issues",
      claim_generation: 1,
      scope: scope,
      created_at: NOW
    )
  end

  def receipt
    @receipt ||= Hive::Modules::Migration::EffectReceipt.build(
      intent: intent,
      status: "committed",
      outcome: { "issue_url" => "https://example.test/issue/7" },
      recorded_at: NOW
    )
  end

  def job
    {
      "occurrence_id" => capture.occurrence_id,
      "source" => {
        "registration" => "demo",
        "repository" => "owner/demo"
      },
      "actions" => []
    }
  end

  def outbox(kind, id, value)
    bytes = Hive::WorkflowPackage::CanonicalJSON.generate(value)
    {
      "kind" => kind,
      "id" => id,
      "digest" => Digest::SHA256.hexdigest(bytes),
      "bytes" => bytes
    }
  end
end
