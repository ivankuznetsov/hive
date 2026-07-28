require "test_helper"
require "hive/refactor_patrol/architecture_occurrence_store"

class RefactorPatrolArchitectureOccurrenceStoreTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 28, 15)
  CorruptRecord = Class.new(StandardError)
  InconsistentRecord = Class.new(StandardError)

  class Binding
    attr_accessor :record
    attr_reader :writes

    def initialize
      @writes = []
    end

    def synchronize(_job_id)
      yield
    end

    def fetch(_job_id)
      record
    end

    def write(job_id, occurrence_id)
      self.record = {
        "job_id" => job_id,
        "occurrence_id" => occurrence_id
      }
      writes << record
      record
    end
  end

  class Journal
    METHODS = %i[
      prepare_effect! effect_state acquire_effect!
      mark_dispatch_uncertain! resolve_absent! settle_reconciled!
      settle_claimed! deny_prepared! receipt effect_receipt_ids finalize!
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

    def projection_pending
      fail_if!(:projection_pending)
      calls << [ :projection_pending ]
      [ record ].compact
    end

    def pending_outbox(occurrence_id)
      fail_if!(:pending_outbox)
      calls << [ :pending_outbox, occurrence_id ]
      outbox
    end

    def acknowledge_outbox!(occurrence_id, **options)
      fail_if!(:acknowledge_outbox!)
      calls << [ :acknowledge_outbox!, occurrence_id, options ]
      true
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

  def test_facade_reserves_one_binding_and_delegates_effect_protocol
    binding = Binding.new
    journal = Journal.new
    store = occurrence_store(binding: binding, journal: journal)

    assert_equal capture.occurrence_id,
                 store.reserve_manifest!(
                   manifest, capture: capture.to_h, now: NOW
                 ).fetch("occurrence_id")
    assert_equal 1, binding.writes.size
    assert_equal capture.occurrence_id,
                 store.reserve!(
                   "job-7", capture: capture, now: NOW
                 ).fetch("occurrence_id")
    assert_equal 1, binding.writes.size
    assert_equal capture.occurrence_id,
                 store.capture_for_job("job-7").occurrence_id
    assert_equal [ capture.occurrence_id ],
                 store.projection_pending.map { |row| row.fetch("occurrence_id") }

    assert_equal :prepare_effect!,
                 store.prepare_effect!(intent.to_h, now: NOW)
    assert_equal :effect_state, store.effect_state(intent)
    assert_equal :acquire_effect!,
                 store.acquire_effect!(
                   intent, claimant: "worker", now: NOW, lease_sec: 10
                 )
    assert_equal :mark_dispatch_uncertain!,
                 store.mark_dispatch_uncertain!(
                   intent, token: "token", now: NOW
                 )
    assert_equal :resolve_absent!,
                 store.resolve_effect_absent!(
                   intent, expected_generation: 1, outcome: {},
                   receipt: receipt, now: NOW
                 )
    assert_equal :settle_reconciled!,
                 store.settle_effect_reconciled!(
                   intent, expected_generation: 1, outcome: {},
                   receipt: receipt, now: NOW
                 )
    assert_equal :settle_claimed!,
                 store.settle_effect_claimed!(
                   intent, token: "token", status: "committed",
                   outcome: {}, receipt: receipt, now: NOW
                 )
    assert_equal :deny_prepared!,
                 store.deny_effect!(
                   intent, outcome: {}, receipt: receipt, now: NOW
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

  def test_binding_conflicts_and_product_scope_mismatches_fail_closed
    binding = Binding.new
    journal = Journal.new
    store = occurrence_store(binding: binding, journal: journal)
    store.reserve!("job-7", capture: capture, now: NOW)

    binding.record = {
      "job_id" => "job-7",
      "occurrence_id" => "occ-#{'f' * 64}"
    }
    assert_raises(InconsistentRecord) do
      store.reserve!("job-7", capture: capture, now: NOW)
    end
    binding.record = {
      "job_id" => "job-7",
      "occurrence_id" => capture.occurrence_id
    }

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
      binding: binding,
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
    binding = Binding.new
    binding.record = {
      "job_id" => "job-7",
      "occurrence_id" => capture.occurrence_id
    }
    journal = Journal.new
    journal.record = {
      "occurrence_id" => capture.occurrence_id,
      "provisional_capture" => capture.to_h
    }
    evidence = Evidence.new
    publisher = Publisher.new
    store = occurrence_store(binding: binding, journal: journal)
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
    binding = Binding.new
    binding.record = {
      "job_id" => "job-7",
      "occurrence_id" => capture.occurrence_id
    }
    journal = Journal.new
    journal.record = {
      "occurrence_id" => capture.occurrence_id,
      "provisional_capture" => capture.to_h
    }
    store = occurrence_store(binding: binding, journal: journal)

    inconsistent_calls = {
      reserve!: -> { store.reserve!("job-7", capture: capture) },
      prepare_effect!: -> { store.prepare_effect!(intent) },
      effect_state: -> { store.effect_state(intent) },
      acquire_effect!: -> {
        store.acquire_effect!(intent, claimant: "worker")
      },
      mark_dispatch_uncertain!: -> {
        store.mark_dispatch_uncertain!(intent, token: "token")
      },
      resolve_absent!: -> {
        store.resolve_effect_absent!(
          intent, expected_generation: 1, outcome: {}, receipt: receipt
        )
      },
      settle_reconciled!: -> {
        store.settle_effect_reconciled!(
          intent, expected_generation: 1, outcome: {}, receipt: receipt
        )
      },
      settle_claimed!: -> {
        store.settle_effect_claimed!(
          intent, token: "token", status: "committed",
          outcome: {}, receipt: receipt
        )
      },
      deny_prepared!: -> {
        store.deny_effect!(intent, outcome: {}, receipt: receipt)
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

  def test_binding_rejects_noncanonical_symlinked_and_unavailable_paths
    with_tmp_dir do |root|
      binding = real_binding(root)
      assert_nil binding.fetch("job-7")
      binding.synchronize("job-7") do
        binding.write("job-7", "occ-#{'a' * 64}")
      end
      assert_equal "occ-#{'a' * 64}",
                   binding.fetch("job-7").fetch("occurrence_id")

      path = binding_path(root)
      File.write(path, JSON.pretty_generate(JSON.parse(File.read(path))))
      assert_raises(CorruptRecord) { binding.fetch("job-7") }

      File.unlink(path)
      target = File.join(root, "target.json")
      File.write(target, "{}")
      File.symlink(target, path)
      assert_raises(CorruptRecord) { binding.fetch("job-7") }

      File.unlink(path)
      File.write(path, "{")
      assert_raises(CorruptRecord) { binding.fetch("job-7") }
    end

    with_tmp_dir do |root|
      blocked_root = File.join(root, "blocked")
      File.write(blocked_root, "not a directory")
      binding = real_binding(blocked_root)
      assert_raises(CorruptRecord) do
        binding.synchronize("job-7") { flunk "lock unexpectedly opened" }
      end
    end
  end

  private

  def occurrence_store(binding:, journal:, job_reader: ->(_job_id) { job })
    Hive::RefactorPatrol::ArchitectureOccurrenceStore.new(
      root: "/unused",
      job_reader: job_reader,
      id_validator: lambda do |job_id|
        raise CorruptRecord, "bad id" unless job_id == "job-7"

        job_id
      end,
      corrupt_record: CorruptRecord,
      inconsistent_record: InconsistentRecord,
      binding: binding,
      journal: journal
    )
  end

  def real_binding(root)
    Hive::RefactorPatrol::ArchitectureOccurrenceBinding.new(
      root: root,
      id_validator: ->(job_id) { job_id },
      corrupt_record: CorruptRecord
    )
  end

  def binding_path(root)
    File.join(root, "occurrences", "jobs", "job-7.json")
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
                  project: nil, reservation: nil, decision: nil)
    source = value.fetch("source")
    Hive::Modules::Migration::PatrolCapture.build(
      module_name: module_name,
      project: project || {
        "project_id" => "project-1",
        "name" => source.fetch("registration"),
        "repository" => source.fetch("repository")
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
      decision_class: "action",
      decision: decision || {
        "rationale" => "due",
        "job_id" => value.fetch("job_id")
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
      outcome: { "url" => "https://example.test/issue/7" },
      recorded_at: NOW
    )
  end

  def job
    {
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
