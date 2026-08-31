require "test_helper"
require "hive/proposals/store"

class ProposalStoreTest < Minitest::Test
  include HiveTestHelper

  def setup
    @tmp = Dir.mktmpdir("proposal-store")
    @root = File.join(@tmp, "proposals", "v1")
    @ids = %w[
      00000000-0000-4000-8000-000000000001
      00000000-0000-4000-8000-000000000002
      00000000-0000-4000-8000-000000000003
    ]
    @store = Hive::Proposals::Store.new(root: @root, id_generator: -> { @ids.shift })
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def test_immutable_record_creation_is_idempotent_and_conflicts_on_changed_content
    first = @store.create_record!(**record_attributes)
    replay = @store.write_record!(first)

    assert_equal first.to_h, replay.to_h
    assert_equal 1, Dir.glob(File.join(@root, "records", "*.json")).length

    changed = first.to_h.merge("motivation" => "Different")
    assert_raises(Hive::Proposals::Conflict) do
      @store.write_record!(Hive::Proposals::Record.new(changed))
    end
    assert_equal first.to_h, @store.fetch_record(first.proposal_id).to_h
  end

  def test_independently_quarantines_invalid_oversize_and_symlinked_neighbors
    valid = @store.create_record!(**record_attributes)
    records = File.join(@root, "records")
    File.write(File.join(records, "prp-00000000-0000-4000-8000-000000000099.json"), "{")
    File.write(
      File.join(records, "prp-00000000-0000-4000-8000-000000000098.json"),
      "x" * (Hive::Proposals::Store::MAX_FILE_BYTES + 1)
    )
    File.symlink(
      File.join(records, "#{valid.proposal_id}.json"),
      File.join(records, "prp-00000000-0000-4000-8000-000000000097.json")
    )

    snapshot = @store.load

    assert_equal [ valid.proposal_id ], snapshot.records.map(&:proposal_id)
    assert_equal %w[invalid_json oversize symlink], snapshot.diagnostics.map(&:code).sort
    snapshot.diagnostics.each do |diagnostic|
      refute_match(/x{32}/, diagnostic.to_h.to_s)
      assert_operator diagnostic.to_h.to_s.bytesize, :<, 1_024
    end
  end

  def test_malformed_event_filename_reserves_its_numeric_slot
    proposal = @store.create_record!(**record_attributes)
    events = File.join(@root, "events", proposal.proposal_id)
    FileUtils.mkdir_p(events)
    File.write(File.join(events, "00000000000000000007-not-an-event.json"), "{}")

    event = @store.append_event!(
      proposal_id: proposal.proposal_id, type: "evaluation",
      source_event_id: "pse-#{'b' * 64}", provenance: provenance,
      occurred_at: "2026-08-30T12:01:00Z",
      data: evaluation_data
    )

    assert_equal 8, event.version
    assert File.file?(File.join(events, "00000000000000000008-#{event.event_id}.json"))
    assert_equal "invalid_event_filename", @store.load.diagnostics.first.code
  end

  def test_changed_source_event_payload_conflicts_without_appending
    proposal = @store.create_record!(**record_attributes)
    first = @store.append_event!(
      proposal_id: proposal.proposal_id, type: "evaluation",
      source_event_id: "pse-#{'b' * 64}", provenance: provenance,
      occurred_at: "2026-08-30T12:01:00Z", data: evaluation_data
    )
    replay = @store.append_event!(
      proposal_id: proposal.proposal_id, type: "evaluation",
      source_event_id: "pse-#{'b' * 64}", provenance: provenance,
      occurred_at: "2026-08-30T12:01:00Z", data: evaluation_data
    )
    assert_equal first.event_id, replay.event_id

    assert_raises(Hive::Proposals::Conflict) do
      @store.append_event!(
        proposal_id: proposal.proposal_id, type: "evaluation",
        source_event_id: "pse-#{'b' * 64}", provenance: provenance,
        occurred_at: "2026-08-30T12:01:00Z",
        data: evaluation_data.merge("rationale" => "changed")
      )
    end
    assert_equal 1, @store.load.events.fetch(proposal.proposal_id).length
  end

  def test_source_event_identity_is_shared_across_records_and_events
    proposal = @store.create_record!(**record_attributes)
    replay = @store.create_record!(**record_attributes)
    assert_equal proposal.proposal_id, replay.proposal_id

    assert_raises(Hive::Proposals::Conflict) do
      @store.create_record!(**record_attributes.merge(motivation: "changed"))
    end
    assert_raises(Hive::Proposals::Conflict) do
      @store.append_event!(
        proposal_id: proposal.proposal_id, type: "evaluation",
        source_event_id: record_attributes.fetch(:source_event_id),
        provenance: provenance, occurred_at: "2026-08-30T12:01:00Z", data: evaluation_data
      )
    end

    event = @store.append_event!(
      proposal_id: proposal.proposal_id, type: "evaluation",
      source_event_id: "pse-#{'b' * 64}", provenance: provenance,
      occurred_at: "2026-08-30T12:01:00Z", data: evaluation_data
    )
    assert_equal event.event_id, @store.fetch_event(event.event_id).event_id
    assert_raises(Hive::Proposals::Conflict) do
      @store.create_record!(**record_attributes.merge(source_event_id: event.source_event_id))
    end
    assert_nil @store.fetch_record("prp-00000000-0000-4000-8000-000000000099")
  end

  def test_existing_event_paths_are_idempotent_and_immutable
    proposal = @store.create_record!(**record_attributes)
    event = @store.append_event!(
      proposal_id: proposal.proposal_id, type: "evaluation",
      source_event_id: "pse-#{'b' * 64}", provenance: provenance,
      occurred_at: "2026-08-30T12:01:00Z", data: evaluation_data
    )

    assert_equal event, @store.send(:write_event_unlocked!, event)
    changed = Hive::Proposals::Event.new(
      event.to_h.merge("data" => event.data.merge("rationale" => "changed"))
    )
    assert_raises(Hive::Proposals::Conflict) do
      @store.send(:write_event_unlocked!, changed)
    end
  end

  def test_atomic_creation_reports_races_and_filesystem_failures
    path = File.join(@root, "manual", "entry.json")
    {
      Errno::EEXIST => Hive::Proposals::Conflict,
      Errno::EACCES => Hive::Proposals::Error
    }.each do |failure, expected|
      replacement = ->(*_arguments, **_options) { raise failure, "simulated" }
      with_replaced_singleton_method(Hive::AtomicFile, :create, replacement) do
        assert_raises(expected) { @store.send(:create_immutable, path, "{}") }
      end
    end
  end

  def test_loader_isolates_invalid_record_and_event_neighbors
    proposal = @store.create_record!(**record_attributes)
    event = @store.append_event!(
      proposal_id: proposal.proposal_id, type: "evaluation",
      source_event_id: "pse-#{'b' * 64}", provenance: provenance,
      occurred_at: "2026-08-30T12:01:00Z", data: evaluation_data
    )
    File.write(File.join(@store.records_root, "README.txt"), "not a record")
    File.write(
      File.join(@store.records_root, "prp-00000000-0000-4000-8000-000000000098.json"),
      Hive::Proposals.canonical({})
    )

    invalid_directory = File.join(@store.events_root, "not-a-proposal")
    FileUtils.mkdir_p(invalid_directory)
    event_directory = File.join(@store.events_root, proposal.proposal_id)
    File.write(
      File.join(event_directory, "00000000000000000002-pev-00000000-0000-4000-8000-000000000002.json"),
      "{not json"
    )
    File.write(
      File.join(event_directory, "00000000000000000003-pev-00000000-0000-4000-8000-000000000003.json"),
      Hive::Proposals.canonical({})
    )
    File.symlink(
      "missing-event.json",
      File.join(event_directory, "00000000000000000004-pev-00000000-0000-4000-8000-000000000004.json")
    )
    mismatched = Hive::Proposals::Event.new(event.to_h.merge("version" => 5))
    File.write(
      File.join(event_directory, "00000000000000000006-#{mismatched.event_id}.json"),
      Hive::Proposals.canonical(mismatched.to_h)
    )

    codes = @store.load.diagnostics.map(&:code)
    %w[
      invalid_record_filename invalid_record invalid_event_directory invalid_json invalid_event symlink
    ].each { |code| assert_includes codes, code }
  end

  def test_duplicate_dangling_and_inconsistent_events_are_independently_diagnosed
    first_id = "prp-00000000-0000-4000-8000-000000000011"
    second_id = "prp-00000000-0000-4000-8000-000000000012"
    shared_event_id = "pev-00000000-0000-4000-8000-000000000099"
    create_record(first_id, source: "1")
    create_record(second_id, source: "2")
    [ [ first_id, "3" ], [ second_id, "4" ] ].each do |id, source|
      @store.append_event!(
        proposal_id: id, type: "evaluation", event_id: shared_event_id,
        source_event_id: source_id(source), provenance: provenance,
        occurred_at: "2026-08-30T12:01:00Z", data: evaluation_data
      )
    end

    dangling_id = "prp-00000000-0000-4000-8000-000000000013"
    dangling = build_event(dangling_id, version: 1, event_id: "pev-00000000-0000-4000-8000-000000000013")
    dangling_path = @store.send(:event_path, dangling)
    FileUtils.mkdir_p(File.dirname(dangling_path))
    File.write(dangling_path, Hive::Proposals.canonical(dangling.to_h))

    codes = @store.load.diagnostics.map(&:code)
    assert_includes codes, "duplicate_event"
    assert_includes codes, "dangling_proposal_reference"
  end

  def test_lineage_mismatches_and_cycles_do_not_poison_unrelated_projections
    predecessor = "prp-00000000-0000-4000-8000-000000000021"
    successor = "prp-00000000-0000-4000-8000-000000000022"
    create_record(predecessor, source: "1")
    create_record(successor, source: "2")
    @store.append_event!(
      proposal_id: predecessor, type: "supersession", source_event_id: source_id("3"),
      provenance: provenance, occurred_at: "2026-08-30T12:01:00Z",
      data: {
        "successor_id" => successor, "authority" => authority,
        "observed_head" => { "version" => 0, "digest" => "d" * 64 }
      }
    )
    assert_includes @store.load.diagnostics.map(&:code), "dangling_or_mismatched_supersession"

    cycle_a = "prp-00000000-0000-4000-8000-000000000023"
    cycle_b = "prp-00000000-0000-4000-8000-000000000024"
    create_record(cycle_a, source: "4", lineage: { "retries" => cycle_b })
    create_record(cycle_b, source: "5", lineage: { "retries" => cycle_a })
    assert_operator @store.load.diagnostics.count { |item| item.code == "lineage_cycle" }, :>=, 2
  end

  def test_safe_reads_report_races_missing_and_unreadable_paths
    path = File.join(@tmp, "bounded-input")
    File.write(path, "safe")
    actual = File.lstat(path)
    raced = Struct.new(:symlink?, :dev, :ino).new(false, actual.dev, actual.ino + 1)
    calls = 0
    original_lstat = File.method(:lstat)
    replacement = lambda do |candidate|
      if candidate == path
        calls += 1
        calls == 1 ? actual : raced
      else
        original_lstat.call(candidate)
      end
    end
    diagnostic = with_replaced_singleton_method(File, :lstat, replacement) do
      @store.send(:safe_read, path, logical_path: "bounded-input")
    end
    assert_equal "raced_file", diagnostic.code

    original_open = File.method(:open)
    replacement = lambda do |candidate, *arguments, **options, &block|
      raise Errno::ELOOP if candidate == path
      original_open.call(candidate, *arguments, **options, &block)
    end
    diagnostic = with_replaced_singleton_method(File, :open, replacement) do
      @store.send(:safe_read, path, logical_path: "bounded-input")
    end
    assert_equal "symlink", diagnostic.code

    assert_equal "missing_file", @store.send(
      :safe_read, File.join(@tmp, "missing"), logical_path: "missing"
    ).code
    replacement = ->(candidate) { candidate == path ? (raise Errno::EACCES) : original_lstat.call(candidate) }
    diagnostic = with_replaced_singleton_method(File, :lstat, replacement) do
      @store.send(:safe_read, path, logical_path: "bounded-input")
    end
    assert_equal "unreadable_file", diagnostic.code

    original_binread = File.method(:binread)
    replacement = lambda do |candidate, *arguments|
      raise IOError, "unreadable" if candidate == path
      original_binread.call(candidate, *arguments)
    end
    assert_equal "", with_replaced_singleton_method(File, :binread, replacement) {
      @store.send(:bounded_file_digest_input, path)
    }
  end

  def test_directory_and_lock_safety_helpers_fail_closed
    assert_raises(Hive::Proposals::Error) do
      @store.send(:ensure_safe_directory!, File.join(@tmp, "outside"))
    end

    unsafe_root = File.join(@tmp, "unsafe-root")
    File.write(unsafe_root, "file")
    unsafe = Hive::Proposals::Store.new(root: unsafe_root)
    assert_raises(Hive::Proposals::Error) { unsafe.send(:ensure_safe_directory!, unsafe_root) }

    raced_directory = File.join(@tmp, "raced-directory")
    original_mkdir = FileUtils.method(:mkdir)
    first = true
    replacement = lambda do |path, **options|
      if path == raced_directory && first
        first = false
        original_mkdir.call(path, **options)
        raise Errno::EEXIST
      end
      original_mkdir.call(path, **options)
    end
    with_replaced_singleton_method(FileUtils, :mkdir, replacement) do
      @store.send(:ensure_one_directory!, raced_directory)
    end
    assert_equal [], @store.send(:children, File.join(@tmp, "missing-directory"))

    @store.send(:ensure_safe_directory!, @root)
    lock_path = File.join(Dir.tmpdir, "hive-proposal-#{Digest::SHA256.hexdigest(@root)}.lock")
    File.unlink(lock_path) if File.exist?(lock_path) || File.symlink?(lock_path)
    File.symlink("missing-lock", lock_path)
    assert_raises(Hive::Proposals::Error) { @store.send(:with_lock) { flunk } }
  ensure
    File.unlink(lock_path) if lock_path && (File.exist?(lock_path) || File.symlink?(lock_path))
  end

  private

  def record_attributes
    {
      subject_kind: "workflow", subject_ref: "coding", revision: "v2",
      proposed_change: "Change review", motivation: "Improve recall",
      evidence: [
        {
          "label" => "score", "content" => "0.91", "visibility" => "project",
          "retention" => "task", "media_type" => "text/plain"
        }
      ],
      author: { "id" => "alice", "kind" => "proposer", "binding" => "team" },
      provenance:, source_event_id: "pse-#{'a' * 64}",
      created_at: "2026-08-30T12:00:00Z",
      policy: { "visibility" => "project", "retention" => "project" }
    }
  end

  def provenance
    {
      "task_id" => "43059", "task_generation" => 1,
      "ownership_generation" => "owner-1", "attempt_id" => "attempt-1",
      "workflow_id" => "coding", "stage" => "4-execute",
      "actor" => { "id" => "alice", "kind" => "configured_identity" },
      "source_commit" => "a" * 40
    }
  end

  def evaluation_data
    {
      "evaluator" => { "id" => "reviewer", "binding_fingerprint" => "b" * 64 },
      "method" => { "kind" => "benchmark", "label" => "recall" },
      "result" => { "outcome" => "pass", "metrics" => { "recall" => 0.91 } },
      "rationale" => "Improved", "evidence" => [], "links" => []
    }
  end

  def create_record(id, source:, lineage: {})
    @store.create_record!(
      proposal_id: id,
      **record_attributes.merge(source_event_id: source_id(source), lineage:)
    )
  end

  def build_event(id, version:, event_id:)
    Hive::Proposals::Event.build(
      event_id:, proposal_id: id, version:, type: "evaluation",
      data: evaluation_data, source_event_id: source_id("e"),
      provenance: provenance, occurred_at: "2026-08-30T12:01:00Z"
    )
  end

  def source_id(character) = "pse-#{character * 64}"

  def authority
    { "id" => "operator", "kind" => "operator", "policy_fingerprint" => "a" * 64 }
  end
end
