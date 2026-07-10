require "test_helper"
require "json"
require "hive/refactor_patrol/family_store"
require "hive/refactor_patrol/thesis"

class RefactorPatrolFamilyStoreTest < Minitest::Test
  include HiveTestHelper

  FamilyStore = Hive::RefactorPatrol::FamilyStore
  SemanticFamily = Hive::RefactorPatrol::SemanticFamily
  T0 = Time.utc(2026, 7, 10, 12, 0, 0)

  def test_creates_a_durable_family_and_returns_resolution_evidence
    with_tmp_dir do |dir|
      store = family_store(dir)
      outcome = store.resolve(
        thesis: thesis,
        repository: "acme/polyglot",
        job_id: "job-1",
        source: source
      )

      assert_equal "new_family", outcome.status
      assert outcome.created
      assert outcome.occurrence_added
      assert outcome.persisted
      assert_equal SemanticFamily.id_for(outcome.descriptor), outcome.family_id
      assert_equal outcome.family_id, outcome.record.fetch("family_id")
      assert_equal "hive-refactor-patrol-family", outcome.record.fetch("schema")
      assert_equal 1, outcome.record.fetch("occurrences").size
      assert_equal "fp-1", outcome.record.dig("occurrences", 0, "fingerprint")
      assert_equal outcome.record, JSON.parse(File.read(File.join(store.root, "#{outcome.family_id}.json")))
      assert File.file?(File.join(store.root, ".lock"))
      assert_empty Dir.glob(File.join(store.root, ".*.tmp.*"))
    end
  end

  def test_aliases_resolve_reruns_and_append_occurrences_idempotently
    with_tmp_dir do |dir|
      store = family_store(dir)
      first = store.resolve(thesis: thesis, repository: "acme/polyglot", job_id: "job-1", source: source)

      same_job = store.resolve(
        thesis: thesis(fingerprint: "fp-2"),
        repository: "acme/polyglot",
        job_id: "job-1",
        source: source("merge_sha" => "b" * 40)
      )
      same_source = store.resolve(
        thesis: thesis(fingerprint: "fp-3"),
        repository: "acme/polyglot",
        job_id: "job-2",
        source: source
      )
      duplicate = store.resolve(
        thesis: thesis(fingerprint: "fp-3"),
        repository: "acme/polyglot",
        job_id: "job-2",
        source: source
      )

      assert_equal [ first.family_id ], [ same_job.family_id, same_source.family_id ].uniq
      assert_equal "occurrence_alias", same_job.reason
      assert_equal "occurrence_alias", same_source.reason
      assert same_job.occurrence_added
      assert same_source.occurrence_added
      refute duplicate.occurrence_added
      assert_equal 3, duplicate.record.fetch("occurrences").size
    end
  end

  def test_structural_match_preserves_immutable_descriptor_and_id
    with_tmp_dir do |dir|
      store = family_store(dir)
      first = store.resolve(thesis: thesis, repository: "acme/polyglot", job_id: "job-1", source: source)
      before = Marshal.load(Marshal.dump(first.record.fetch("descriptor")))
      reworded = thesis(
        id: "checkout-refactor-2",
        fingerprint: "fp-reworded",
        problem: "Payment routing repeats authorization policy in several handlers",
        proposed_refactor: "Centralize payment authorization policy"
      )

      matched = store.resolve(
        thesis: reworded,
        repository: "acme/polyglot",
        job_id: "job-2",
        source: source("number" => 43, "url" => "https://example.test/acme/polyglot/pull/43")
      )

      assert_equal "matched", matched.status
      assert_equal "structural_match", matched.reason
      assert_equal first.family_id, matched.family_id
      assert_equal before, matched.record.fetch("descriptor")
      assert_equal 2, matched.record.fetch("occurrences").size
    end
  end

  def test_dry_run_returns_preview_without_creating_state
    with_tmp_dir do |dir|
      store = family_store(dir)

      outcome = store.resolve(
        thesis: thesis,
        repository: "acme/polyglot",
        job_id: "job-dry",
        source: source,
        dry_run: true
      )

      assert_equal "new_family", outcome.status
      refute outcome.created
      refute outcome.persisted
      assert outcome.would_create
      assert outcome.would_append
      assert_equal "job-dry", outcome.record.dig("occurrences", 0, "job_id")
      refute Dir.exist?(File.join(dir, ".hive-state"))
    end
  end

  def test_ambiguous_structural_match_is_visible_and_writes_nothing
    with_tmp_dir do |dir|
      store = family_store(dir)
      FileUtils.mkdir_p(store.root)
      first = record("af1-first", descriptor)
      second = record("af1-second", descriptor("concepts" => %w[authorization checkout payment routing validation]))
      write_record(store, first)
      write_record(store, second)
      before = family_bytes(store)

      outcome = store.resolve(
        thesis: thesis(fingerprint: "fp-new"),
        repository: "acme/polyglot",
        job_id: "job-new",
        source: source("number" => 99)
      )

      assert_equal "family_ambiguous", outcome.status
      assert_equal %w[af1-first af1-second], outcome.matched_family_ids
      assert_nil outcome.record
      refute outcome.persisted
      assert_equal before, family_bytes(store)
    end
  end

  def test_conflicting_occurrence_alias_is_ambiguous_and_does_not_mutate_records
    with_tmp_dir do |dir|
      store = family_store(dir)
      FileUtils.mkdir_p(store.root)
      occurrence = occurrence_for(thesis, "job-old", source)
      write_record(store, record("af1-first", descriptor, occurrences: [ occurrence ]))
      other = descriptor(
        "component" => "architecture-other",
        "anchors" => [ "src/other/core.ts" ],
        "concepts" => %w[dispatch event queue]
      )
      write_record(store, record("af1-second", other, occurrences: [ occurrence ]))
      before = family_bytes(store)

      outcome = store.resolve(
        thesis: thesis,
        repository: "acme/polyglot",
        job_id: "job-new",
        source: source
      )

      assert_equal "family_ambiguous", outcome.status
      assert_equal "conflicting_occurrence_alias", outcome.reason
      assert_equal %w[af1-first af1-second], outcome.matched_family_ids
      assert_equal before, family_bytes(store)
    end
  end

  def test_unknown_and_incompatible_hints_fail_closed
    with_tmp_dir do |dir|
      store = family_store(dir)
      created = store.resolve(thesis: thesis, repository: "acme/polyglot", job_id: "job-1", source: source)
      before = family_bytes(store)

      unknown = store.resolve(
        thesis: thesis(id: "other", fingerprint: "fp-other"),
        repository: "acme/polyglot",
        job_id: "job-2",
        source: source("number" => 43),
        hinted_family_id: "af1-missing"
      )
      incompatible = store.resolve(
        thesis: thesis(
          id: "different",
          fingerprint: "fp-different",
          feature_id: "architecture-events",
          evidence: [ { "file" => "src/events/core.ts", "line" => 1, "claim" => "Events form a dependency cycle" } ],
          problem: "Events form a dependency cycle",
          proposed_refactor: "Invert event dependency ownership"
        ),
        repository: "acme/polyglot",
        job_id: "job-3",
        source: source("number" => 44),
        hinted_family_id: created.family_id
      )

      assert_equal "unknown_family_hint", unknown.reason
      assert_equal "family_ambiguous", unknown.status
      assert_equal "incompatible_family_hint", incompatible.reason
      assert_equal before, family_bytes(store)
    end
  end

  def test_corrupt_newer_and_conflicting_records_fail_closed_without_rewrite
    with_tmp_dir do |dir|
      store = family_store(dir)
      FileUtils.mkdir_p(store.root)

      corrupt_path = File.join(store.root, "af1-corrupt.json")
      File.binwrite(corrupt_path, "{")
      assert_fail_closed(store, corrupt_path, FamilyStore::CorruptRecord)
      FileUtils.rm_f(corrupt_path)

      newer_path = File.join(store.root, "af1-newer.json")
      File.binwrite(newer_path, JSON.generate(record("af1-newer", descriptor).merge("schema_version" => 99)))
      assert_fail_closed(store, newer_path, FamilyStore::UnsupportedVersion)
      FileUtils.rm_f(newer_path)

      conflict_path = File.join(store.root, "af1-filename.json")
      File.binwrite(conflict_path, JSON.generate(record("af1-payload", descriptor)))
      assert_fail_closed(store, conflict_path, FamilyStore::InconsistentRecord)
    end
  end

  def test_malformed_occurrence_source_is_a_typed_corrupt_record
    with_tmp_dir do |dir|
      store = family_store(dir)
      FileUtils.mkdir_p(store.root)
      malformed = record(
        "af1-malformed-source",
        descriptor,
        occurrences: [ occurrence_for(thesis, "job-old", source).merge("source" => [ "not", "an", "object" ]) ]
      )
      path = File.join(store.root, "af1-malformed-source.json")
      File.binwrite(path, JSON.generate(malformed))

      assert_fail_closed(store, path, FamilyStore::CorruptRecord)
    end
  end

  def test_deterministic_id_detects_descriptor_tampering
    with_tmp_dir do |dir|
      store = family_store(dir)
      created = store.resolve(thesis: thesis, repository: "acme/polyglot", job_id: "job-1", source: source)
      path = File.join(store.root, "#{created.family_id}.json")
      tampered = JSON.parse(File.read(path))
      tampered["descriptor"]["concepts"] = %w[different semantic subject]
      File.binwrite(path, JSON.generate(tampered))

      assert_fail_closed(store, path, FamilyStore::InconsistentRecord)
    end
  end

  def test_explicit_repository_cannot_disagree_with_source
    with_tmp_dir do |dir|
      store = family_store(dir)

      error = assert_raises(ArgumentError) do
        store.resolve(
          thesis: thesis,
          repository: "other/repository",
          job_id: "job-1",
          source: source,
          dry_run: true
        )
      end

      assert_includes error.message, "conflicts"
      refute Dir.exist?(File.join(dir, ".hive-state"))
    end
  end

  def test_concurrent_resolution_uses_one_store_lock_and_keeps_all_occurrences
    with_tmp_dir do |dir|
      store = family_store(dir)
      threads = 8.times.map do |index|
        Thread.new do
          store.resolve(
            thesis: thesis(id: "checkout-#{index}", fingerprint: "fp-#{index}"),
            repository: "acme/polyglot",
            job_id: "job-#{index}",
            source: source("number" => index + 1, "url" => "https://example.test/acme/polyglot/pull/#{index + 1}")
          )
        end
      end
      outcomes = threads.map(&:value)

      assert_equal 1, outcomes.map(&:family_id).uniq.size
      records = Dir.glob(File.join(store.root, "*.json"))
      assert_equal 1, records.size
      assert_equal 8, JSON.parse(File.read(records.first)).fetch("occurrences").size
      assert_equal [ File.join(store.root, ".lock") ], Dir.glob(File.join(store.root, "*.lock"), File::FNM_DOTMATCH)
    end
  end

  def test_failed_atomic_append_preserves_the_old_record_and_retry_converges
    with_tmp_dir do |dir|
      store = family_store(dir)
      created = store.resolve(thesis: thesis, repository: "acme/polyglot", job_id: "job-1", source: source)
      path = File.join(store.root, "#{created.family_id}.json")
      before = File.binread(path)
      replacement = ->(*_args, **_kwargs) { raise Errno::ENOSPC, "injected" }

      assert_raises(Errno::ENOSPC) do
        with_replaced_singleton_method(Hive::AtomicFile, :write, replacement) do
          store.resolve(
            thesis: thesis(id: "checkout-2", fingerprint: "fp-2"),
            repository: "acme/polyglot",
            job_id: "job-2",
            source: source("number" => 43)
          )
        end
      end
      assert_equal before, File.binread(path)

      retried = store.resolve(
        thesis: thesis(id: "checkout-2", fingerprint: "fp-2"),
        repository: "acme/polyglot",
        job_id: "job-2",
        source: source("number" => 43)
      )
      assert retried.occurrence_added
      assert_equal 2, retried.record.fetch("occurrences").size
    end
  end

  private

  def family_store(dir)
    FamilyStore.new(dir, clock: -> { T0 })
  end

  def source(overrides = {})
    {
      "repository" => "acme/polyglot",
      "number" => 42,
      "url" => "https://example.test/acme/polyglot/pull/42",
      "merge_sha" => "a" * 40
    }.merge(overrides)
  end

  def thesis(id: "checkout-refactor-1", fingerprint: "fp-1",
             feature_id: "architecture-services-checkout-part-2",
             problem: "Validation policy is duplicated across payment routing handlers",
             proposed_refactor: "Consolidate checkout validation policy behind one payment routing decision",
             evidence: nil)
    Hive::RefactorPatrol::Thesis.new(
      id: id,
      feature_id: feature_id,
      feature: "Checkout routing",
      problem: problem,
      cost: "Payment changes repeatedly touch authorization and routing",
      evidence: evidence || [
        { "file" => "services/checkout/route.ts", "line" => 12, "claim" => "Payment routing repeats checkout validation policy" },
        { "file" => "services/checkout/authorize.ts", "line" => 24, "claim" => "Checkout authorization repeats validation" }
      ],
      proposed_refactor: proposed_refactor,
      feature_boundary: {
        "owned_files" => %w[services/checkout/authorize.ts services/checkout/route.ts],
        "entrypoints" => [ "services/checkout/route.ts" ]
      },
      feature_hotspot: {},
      expected_leverage: {
        "drivers" => [
          { "signal" => "coupling", "relief" => 0.5, "mechanism" => "Give checkout one validation policy" }
        ]
      },
      confidence: "high",
      risk: {},
      required_validation: {},
      admissible: true,
      admissibility_reason: "anchored",
      follow_up_approval_state: "pending",
      fingerprint: fingerprint
    )
  end

  def descriptor(overrides = {})
    Hive::RefactorPatrol::SemanticFamily.descriptor(
      repository: "acme/polyglot",
      component: "architecture-services-checkout",
      problem_kind: "duplicated_policy",
      refactor_kind: "consolidate_policy",
      anchors: %w[services/checkout/authorize.ts services/checkout/route.ts],
      concepts: %w[authorization checkout handler payment routing validation]
    ).merge(overrides)
  end

  def occurrence_for(item, job_id, item_source)
    {
      "fingerprint" => item.fingerprint,
      "job_id" => job_id,
      "thesis_id" => item.id,
      "source" => item_source.slice("repository", "url", "number", "merge_sha")
    }
  end

  def record(id, item_descriptor, occurrences: [])
    {
      "schema" => "hive-refactor-patrol-family",
      "schema_version" => 1,
      "family_id" => id,
      "descriptor" => item_descriptor,
      "occurrences" => occurrences,
      "created_at" => T0.iso8601,
      "updated_at" => T0.iso8601
    }
  end

  def write_record(store, data)
    File.binwrite(File.join(store.root, "#{data.fetch("family_id")}.json"), "#{JSON.pretty_generate(data)}\n")
  end

  def family_bytes(store)
    Dir.glob(File.join(store.root, "*.json")).sort.to_h { |path| [ path, File.binread(path) ] }
  end

  def assert_fail_closed(store, path, error)
    before = File.binread(path)
    assert_raises(error) do
      store.resolve(thesis: thesis, repository: "acme/polyglot", job_id: "job-new", source: source)
    end
    assert_equal before, File.binread(path)
  end
end
