require "test_helper"
require "json"
require "hive/refactor_patrol/family_store"
require "hive/refactor_patrol/job_store"
require "hive/refactor_patrol/thesis"

class RefactorPatrolFamilyStoreTest < Minitest::Test
  include HiveTestHelper

  FamilyStore = Hive::RefactorPatrol::FamilyStore
  SemanticFamily = Hive::RefactorPatrol::SemanticFamily
  T0 = Time.utc(2026, 7, 10, 12, 0, 0)

  def test_default_clock_and_unreadable_registry_fallback_are_safe
    with_tmp_dir do |dir|
      store = nil
      with_replaced_singleton_method(
        Hive::Config,
        :registered_projects,
        -> { raise Hive::ConfigError, "registry unavailable" }
      ) do
        store = FamilyStore.new(dir, job_store: Object.new)
      end

      assert_instance_of Time, store.instance_variable_get(:@clock).call
      factory = store.instance_variable_get(:@job_store_factory)
      built = factory.call(migrate: false)
      assert_nil built.instance_variable_get(:@project)
    end
  end

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

  def test_rebuilds_a_missing_or_corrupt_family_from_authoritative_jobs_before_matching_reworded_work
    %i[missing corrupt].each do |damage|
      with_tmp_dir do |dir|
        store = family_store(dir)
        original = thesis
        first = store.resolve(
          thesis: original,
          repository: "acme/polyglot",
          job_id: "job-1",
          source: source
        )
        write_authoritative_family_job(dir, original, first.family_id)
        path = File.join(store.root, "#{first.family_id}.json")
        damage == :missing ? FileUtils.rm_f(path) : File.binwrite(path, "{")

        reworded = thesis(
          id: "checkout-refactor-2",
          fingerprint: "fp-reworded",
          problem: "Payment routing repeats authorization policy in several handlers",
          proposed_refactor: "Centralize payment authorization policy"
        )
        matched = nil
        capture_io do
          matched = store.resolve(
            thesis: reworded,
            repository: "acme/polyglot",
            job_id: "job-2",
            source: source("number" => 43, "url" => "https://example.test/acme/polyglot/pull/43")
          )
        end

        assert_equal first.family_id, matched.family_id, damage
        assert_equal "structural_match", matched.reason, damage
        rebuilt = JSON.parse(File.read(path))
        assert_equal first.descriptor, rebuilt.fetch("descriptor"), damage
        assert_equal %w[job-1 job-2], rebuilt.fetch("occurrences").map { |item| item.fetch("job_id") }, damage
      end
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

  def test_unsupported_newer_schema_version_fails_closed_without_rewrite_or_quarantine
    with_tmp_dir do |dir|
      store = family_store(dir)
      FileUtils.mkdir_p(store.root)
      newer_path = File.join(store.root, "af1-newer.json")
      File.binwrite(newer_path, JSON.generate(record("af1-newer", descriptor).merge("schema_version" => 99)))

      assert_fail_closed(store, newer_path, FamilyStore::UnsupportedVersion)
      assert_empty quarantined_family_records(dir)
    end
  end

  def test_corrupt_and_inconsistent_records_are_quarantined_with_bytes_preserved
    {
      "af1-corrupt" => "{",
      "af1-filename" => JSON.generate(record("af1-payload", descriptor))
    }.each do |family_id, bytes|
      with_tmp_dir do |dir|
        store = family_store(dir)
        FileUtils.mkdir_p(store.root)
        path = File.join(store.root, "#{family_id}.json")
        File.binwrite(path, bytes)

        outcome = nil
        capture_io do
          outcome = store.resolve(thesis: thesis, repository: "acme/polyglot", job_id: "job-new", source: source)
        end

        assert_equal "new_family", outcome.status, family_id
        refute File.exist?(path), family_id
        quarantined = quarantined_family_records(dir, family_id)
        assert_equal 1, quarantined.size, family_id
        assert_equal bytes, File.binread(quarantined.first), family_id
        evidence = JSON.parse(File.read("#{quarantined.first}.evidence.json"))
        assert_equal "#{family_id}.json", evidence.fetch("family_record"), family_id
        refute_empty evidence.fetch("error"), family_id
      end
    end
  end

  def test_quarantine_failure_preserves_the_original_corrupt_record_error
    with_tmp_dir do |dir|
      store = family_store(dir)
      path = File.join(store.root, "af1-corrupt.json")
      error = FamilyStore::CorruptRecord.new("invalid JSON", path: path)
      replacement = lambda { |_source, _destination| raise Errno::EACCES, path }

      raised = with_replaced_singleton_method(File, :rename, replacement) do
        assert_raises(FamilyStore::CorruptRecord) do
          store.send(:quarantine_record!, path, error)
        end
      end

      assert_same error, raised
    end
  end

  # Regression for the bulk-delete on one corrupt record: the old recovery
  # rebuilt solely from authoritative job aggregates and deleted every file
  # outside that set, destroying pre-authoritative families and changing
  # later SemanticFamily.resolve outcomes (duplicate GitHub issues).
  def test_one_corrupt_record_never_discards_valid_or_pre_authoritative_families
    with_tmp_dir do |dir|
      store = family_store(dir)
      authoritative = store.resolve(thesis: thesis, repository: "acme/polyglot", job_id: "job-1", source: source)
      write_authoritative_family_job(dir, thesis, authoritative.family_id)
      pre_authoritative = store.resolve(
        thesis: thesis(
          id: "events-refactor-1",
          fingerprint: "fp-events",
          feature_id: "architecture-events",
          evidence: [ { "file" => "src/events/core.ts", "line" => 1, "claim" => "Events form a dependency cycle" } ],
          problem: "Events form a dependency cycle",
          proposed_refactor: "Invert event dependency ownership"
        ),
        repository: "acme/polyglot",
        job_id: "job-2",
        source: source("number" => 43, "url" => "https://example.test/acme/polyglot/pull/43")
      )
      corrupt_path = File.join(store.root, "af1-corrupt.json")
      File.binwrite(corrupt_path, "{")

      retried = nil
      capture_io do
        retried = store.resolve(
          thesis: thesis(id: "checkout-refactor-3", fingerprint: "fp-3"),
          repository: "acme/polyglot",
          job_id: "job-3",
          source: source("number" => 44, "url" => "https://example.test/acme/polyglot/pull/44")
        )
      end

      assert_equal authoritative.family_id, retried.family_id
      assert File.file?(File.join(store.root, "#{pre_authoritative.family_id}.json")),
             "pre-authoritative family must survive corrupt-record recovery"
      refute File.exist?(corrupt_path)
      quarantined = quarantined_family_records(dir, "af1-corrupt")
      assert_equal 1, quarantined.size
      assert_equal "{", File.binread(quarantined.first)
    end
  end

  def test_dry_run_skips_quarantine_and_still_resolves_from_valid_records
    with_tmp_dir do |dir|
      store = family_store(dir)
      created = store.resolve(thesis: thesis, repository: "acme/polyglot", job_id: "job-1", source: source)
      corrupt_path = File.join(store.root, "af1-corrupt.json")
      File.binwrite(corrupt_path, "{")

      outcome = store.resolve(
        thesis: thesis(fingerprint: "fp-2"),
        repository: "acme/polyglot",
        job_id: "job-2",
        source: source("number" => 43),
        dry_run: true
      )

      assert_equal created.family_id, outcome.family_id
      refute outcome.persisted
      assert File.file?(corrupt_path), "a dry run must not quarantine or mutate state"
      assert_empty quarantined_family_records(dir)
    end
  end

  def test_malformed_occurrence_source_is_a_typed_corrupt_record_and_quarantines
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

      error = assert_raises(FamilyStore::CorruptRecord) { store.send(:read_record, path) }
      assert_equal path, error.path

      capture_io { store.resolve(thesis: thesis, repository: "acme/polyglot", job_id: "job-new", source: source) }
      assert_equal 1, quarantined_family_records(dir, "af1-malformed-source").size
    end
  end

  def test_deterministic_id_detects_descriptor_tampering_and_quarantines_the_record
    with_tmp_dir do |dir|
      store = family_store(dir)
      created = store.resolve(thesis: thesis, repository: "acme/polyglot", job_id: "job-1", source: source)
      path = File.join(store.root, "#{created.family_id}.json")
      tampered = JSON.parse(File.read(path))
      tampered["descriptor"]["concepts"] = %w[different semantic subject]
      File.binwrite(path, JSON.generate(tampered))
      tampered_bytes = File.binread(path)

      assert_raises(FamilyStore::InconsistentRecord) { store.send(:read_record, path) }

      capture_io { store.resolve(thesis: thesis, repository: "acme/polyglot", job_id: "job-new", source: source) }
      quarantined = quarantined_family_records(dir, created.family_id)
      assert_equal 1, quarantined.size
      assert_equal tampered_bytes, File.binread(quarantined.first)
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

  def test_record_io_failures_are_wrapped_with_the_family_path
    with_tmp_dir do |dir|
      store = family_store(dir)
      FileUtils.mkdir_p(store.root)

      read_error = assert_raises(FamilyStore::CorruptRecord) do
        store.send(:read_record, store.root)
      end
      assert_equal store.root, read_error.path
      assert_includes read_error.message, "cannot read"

      root = store.root
      replacement = lambda do |pattern|
        raise IOError, "directory vanished" if pattern == File.join(root, "*.json")

        []
      end
      with_replaced_singleton_method(Dir, :glob, replacement) do
        enumerate_error = assert_raises(FamilyStore::CorruptRecord) { store.send(:record_paths) }
        assert_equal root, enumerate_error.path
        assert_includes enumerate_error.message, "cannot enumerate"
      end
    end
  end

  def test_invalid_descriptor_repository_and_timestamp_are_typed
    with_tmp_dir do |dir|
      store = family_store(dir)
      FileUtils.mkdir_p(store.root)

      invalid_descriptor = record("af1-invalid-descriptor", descriptor).merge("descriptor" => [])
      descriptor_path = File.join(store.root, "af1-invalid-descriptor.json")
      File.binwrite(descriptor_path, JSON.generate(invalid_descriptor))
      error = assert_raises(FamilyStore::CorruptRecord) { store.send(:read_record, descriptor_path) }
      assert_includes error.message, "descriptor is invalid"
      FileUtils.rm_f(descriptor_path)

      invalid_timestamp = record("af1-invalid-time", descriptor).merge("created_at" => "yesterday")
      timestamp_path = File.join(store.root, "af1-invalid-time.json")
      File.binwrite(timestamp_path, JSON.generate(invalid_timestamp))
      error = assert_raises(FamilyStore::CorruptRecord) { store.send(:read_record, timestamp_path) }
      assert_includes error.message, "ISO-8601"
      FileUtils.rm_f(timestamp_path)

      error = assert_raises(ArgumentError) do
        store.resolve(
          thesis: thesis, repository: "not-a-slug", job_id: "job-new",
          source: source, dry_run: true
        )
      end
      assert_includes error.message, "owner/name"
    end
  end

  def test_rebuild_removes_orphaned_projection_records
    with_tmp_dir do |dir|
      store = family_store(dir)
      FileUtils.mkdir_p(store.root)
      orphan = record("af1-orphan", descriptor)
      write_record(store, orphan)

      assert_equal [], store.rebuild!
      refute File.exist?(File.join(store.root, "af1-orphan.json"))
      assert File.file?(File.join(store.root, ".lock"))
    end
  end

  def test_authoritative_jobs_without_thesis_or_owner_fail_closed
    with_tmp_dir do |dir|
      missing_thesis = authoritative_aggregate(
        thesis_snapshot: nil,
        owner_job_id: "job-1"
      )
      missing_thesis["dispositions"] = {}
      store = family_store(dir, jobs: [ missing_thesis ])
      error = assert_raises(FamilyStore::InconsistentRecord) { store.rebuild! }
      assert_includes error.message, "lacks a thesis snapshot"

      missing_owner = authoritative_aggregate(owner_job_id: "another-job")
      store = family_store(dir, jobs: [ missing_owner ])
      error = assert_raises(FamilyStore::InconsistentRecord) { store.rebuild! }
      assert_includes error.message, "one authoritative owner"
    end
  end

  def test_authoritative_job_read_and_shape_errors_are_wrapped
    with_tmp_dir do |dir|
      broken_store = Object.new
      job_error = Hive::RefactorPatrol::JobStore::CorruptRecord.new("broken job", path: "/tmp/job.json")
      broken_store.define_singleton_method(:jobs) { raise job_error }
      store = FamilyStore.new(dir, clock: -> { T0 }, job_store: broken_store)
      error = assert_raises(FamilyStore::InconsistentRecord) { store.rebuild! }
      assert_equal "/tmp/job.json", error.path
      assert_includes error.message, "cannot rebuild"

      store = family_store(dir, jobs: [ {} ])
      error = assert_raises(FamilyStore::InconsistentRecord) { store.rebuild! }
      assert_includes error.message, "cannot rebuild"
    end
  end

  def test_invalid_authoritative_timestamp_fails_closed
    with_tmp_dir do |dir|
      aggregate = authoritative_aggregate
      aggregate["actions"][0]["created_at"] = "invalid"
      store = family_store(dir, jobs: [ aggregate ])

      error = assert_raises(FamilyStore::InconsistentRecord) { store.rebuild! }

      assert_includes error.message, "invalid timestamp"
    end
  end

  def test_stale_projection_merges_authoritative_occurrences_before_append
    with_tmp_dir do |dir|
      store = family_store(dir)
      first = store.resolve(
        thesis: thesis, repository: "acme/polyglot", job_id: "job-1", source: source
      )
      write_authoritative_family_job(dir, thesis, first.family_id)
      path = File.join(store.root, "#{first.family_id}.json")
      stale = JSON.parse(File.read(path))
      stale["occurrences"] = []
      File.binwrite(path, JSON.generate(stale))

      result = store.resolve(
        thesis: thesis(id: "checkout-refactor-2", fingerprint: "fp-2"),
        repository: "acme/polyglot", job_id: "job-2", source: source("number" => 43)
      )

      assert_equal first.family_id, result.family_id
      assert_equal %w[job-1 job-2], result.record.fetch("occurrences").map { |item| item.fetch("job_id") }
    end
  end

  private

  def family_store(dir, jobs: nil)
    job_store = if jobs
      Object.new.tap { |fake| fake.define_singleton_method(:jobs) { jobs } }
    end
    FamilyStore.new(dir, clock: -> { T0 }, job_store: job_store)
  end

  def authoritative_aggregate(thesis_snapshot: thesis.to_h, owner_job_id: "job-1")
    {
      "job_id" => "job-1",
      "source" => source,
      "dispositions" => {
        "flagged" => [ { "id" => thesis.id, "thesis" => thesis_snapshot } ]
      },
      "actions" => [
        {
          "kind" => "issue",
          "family_id" => "af1-authoritative",
          "thesis_id" => thesis.id,
          "canonical_action_id" => "issue-authoritative",
          "owner_job_id" => owner_job_id,
          "created_at" => T0.iso8601,
          "updated_at" => T0.iso8601
        }
      ],
      "created_at" => T0.iso8601,
      "updated_at" => T0.iso8601
    }
  end

  def write_authoritative_family_job(dir, item, family_id)
    store = Hive::RefactorPatrol::JobStore.new(dir)
    store.write_job!(
      {
        "schema" => "hive-refactor-patrol-job",
        "schema_version" => Hive::RefactorPatrol::JobStore::SCHEMA_VERSION,
        "job_id" => "job-1",
        "occurrence_id" => "occ-#{'1' * 64}",
        "intake_transition_id" => "intent-#{'2' * 64}",
        "source" => source.merge(
          "registration" => "polyglot",
          "base_branch" => "main",
          "base_sha" => "b" * 40
        ),
        "analysis_sha" => "c" * 40,
        "policy" => { "discovery" => true, "auto_fix" => false, "issue_filing" => true },
        "state" => "classified",
        "complete" => false,
        "dispositions" => {
          "accepted" => [],
          "flagged" => [
            {
              "id" => item.id,
              "feature_id" => item.feature_id,
              "fingerprint" => item.fingerprint,
              "score" => 0.8,
              "admissible" => true,
              "reasons" => [ "cross_feature_impact" ],
              "thesis" => item.to_h
            }
          ],
          "suppressed" => []
        },
        "feature_results" => [],
        "review_errors" => [],
        "zero_reason" => nil,
        "attempts" => [ { "number" => 1, "outcome" => "classified" } ],
        "actions" => [],
        "created_at" => T0.iso8601,
        "updated_at" => T0.iso8601
      }
    )
    store.initialize_actions!(
      "job-1",
      specifications: [ { "thesis_id" => item.id, "kind" => "issue", "family_id" => family_id } ],
      now: T0
    )
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
      host: "example.test",
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

  # Quarantined family records live beside (not under) the families root so
  # record enumeration never re-reads them; evidence sidecars are excluded.
  def quarantined_family_records(dir, family_id = nil)
    pattern = "#{family_id ? "#{family_id}-" : ''}*.json"
    Dir.glob(File.join(dir, ".hive-state", "refactor_patrol", "v2", "quarantine", "families", pattern))
       .reject { |path| path.end_with?(".evidence.json") }
       .sort
  end

  def assert_fail_closed(store, path, error)
    before = File.binread(path)
    assert_raises(error) do
      store.resolve(thesis: thesis, repository: "acme/polyglot", job_id: "job-new", source: source)
    end
    assert_equal before, File.binread(path)
  end
end
