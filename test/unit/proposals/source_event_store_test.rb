require "test_helper"
require "hive/proposals/source_event_store"

class ProposalSourceEventStoreTest < Minitest::Test
  include HiveTestHelper

  def test_admits_immutable_receipts_tracks_only_pending_ids_and_is_idempotent
    with_tmp_dir do |dir|
      store = Hive::Proposals::SourceEventStore.new(root: dir, limits: limits)
      event = source_event

      result = store.admit!(event)
      replay = store.admit!(event)

      assert_equal event.source_event_id, result.source_event_id
      assert_equal result.to_h, replay.to_h
      assert_equal [ event.source_event_id ], store.pending_ids
      assert_equal event.to_h, store.fetch(event.source_event_id).to_h

      store.mark_consumed!(event.source_event_id, result: { "proposal_id" => event.proposal_id })

      assert_empty store.pending_ids
      assert_equal "consumed", store.status(event.source_event_id).fetch("state")
      assert_equal 1, store.index.fetch("consumed_count")
    end
  end

  def test_conflicts_on_changed_replay_and_fails_quota_before_a_second_receipt
    with_tmp_dir do |dir|
      store = Hive::Proposals::SourceEventStore.new(
        root: dir, limits: limits.merge("max_pending_sources" => 1)
      )
      store.admit!(source_event)

      changed = Hive::Proposals::SourceEvent.new(
        source_event.to_h.merge("created_at" => "2026-08-30T12:00:01.000000Z")
      )
      assert_raises(Hive::Proposals::Conflict) { store.admit!(changed) }

      second = Hive::Proposals::SourceEvent.new(
        source_event.to_h.merge("source_event_id" => "pse-#{'d' * 64}")
      )
      assert_raises(Hive::Proposals::QuotaExceeded) { store.admit!(second) }
      assert_equal [ source_event.source_event_id ], store.pending_ids
    end
  end

  def test_enforces_the_per_proposal_event_ceiling_after_consumption
    with_tmp_dir do |dir|
      store = Hive::Proposals::SourceEventStore.new(
        root: dir, limits: limits.merge("max_proposal_events" => 1)
      )
      store.admit!(source_event)
      store.mark_consumed!(
        source_event.source_event_id,
        result: {
          "kind" => "record", "proposal_id" => source_event.proposal_id,
          "event_id" => nil, "source_event_id" => source_event.source_event_id
        }
      )
      second = Hive::Proposals::SourceEvent.new(
        source_event.to_h.merge("source_event_id" => "pse-#{'d' * 64}")
      )

      assert_raises(Hive::Proposals::QuotaExceeded) { store.admit!(second) }
      assert_empty store.pending_ids
      assert_equal 1, store.index.dig("proposal_usage", source_event.proposal_id, "sources")
    end
  end

  def test_status_and_concurrent_creation_fail_without_mutating_the_index
    with_tmp_dir do |dir|
      store = Hive::Proposals::SourceEventStore.new(root: dir, limits: limits)
      assert_nil store.status("pse-#{'b' * 64}")

      replacement = lambda do |*_arguments, **_options|
        raise Errno::EEXIST, "simulated concurrent receipt"
      end
      with_replaced_singleton_method(Hive::AtomicFile, :create, replacement) do
        assert_raises(Hive::Proposals::Conflict) { store.admit!(source_event) }
      end
      assert_empty store.pending_ids
    end
  end

  def test_all_admission_and_terminal_quota_dimensions_fail_closed
    quota_cases = [
      [ { "max_project_events" => 1 }, ->(index) { index["total_sources"] = 1 },
        /project event quota/ ],
      [ { "max_project_bytes" => 1 }, ->(index) { index["total_bytes"] = 1 },
        /project byte quota/ ],
      [ { "max_proposal_bytes" => 1 },
        ->(index) { index["proposal_usage"][source_event.proposal_id] = { "sources" => 0, "bytes" => 1 } },
        /proposal byte quota/ ],
      [ { "max_sources_per_actor_per_hour" => 1 }, ->(_index) { }, /rate limit/ ]
    ]
    quota_cases.each do |overrides, mutate, message|
      store = Hive::Proposals::SourceEventStore.new(
        root: Dir.mktmpdir("proposal-source-quota"), limits: limits.merge(overrides),
        clock: -> { Time.utc(2026, 8, 30, 12, 0, 0) }
      )
      index = store.send(:empty_index)
      mutate.call(index)
      recent = message == /rate limit/ ?
        [ { "actor_id" => "alice", "at" => "2026-08-30T12:00:00Z" } ] : []
      error = assert_raises(Hive::Proposals::QuotaExceeded) do
        store.send(:enforce_quotas!, index, source_event, 2, recent_admissions: recent)
      end
      assert_match(message, error.message)
    ensure
      FileUtils.rm_rf(store&.root)
    end

    store = Hive::Proposals::SourceEventStore.new(
      root: Dir.mktmpdir("proposal-terminal-quota"),
      limits: limits.merge("max_project_bytes" => 1)
    )
    index = store.send(:empty_index).merge("total_bytes" => 1)
    assert_raises(Hive::Proposals::QuotaExceeded) do
      store.send(:enforce_terminal_bytes!, index, nil, 1)
    end
    FileUtils.rm_rf(store.root)

    store = Hive::Proposals::SourceEventStore.new(
      root: Dir.mktmpdir("proposal-terminal-quota"),
      limits: limits.merge("max_proposal_bytes" => 1)
    )
    index = store.send(:empty_index)
    index["proposal_usage"][source_event.proposal_id] = { "sources" => 1, "bytes" => 1 }
    assert_raises(Hive::Proposals::QuotaExceeded) do
      store.send(:enforce_terminal_bytes!, index, source_event.proposal_id, 1)
    end
  ensure
    FileUtils.rm_rf(store&.root)
  end

  def test_invalid_rate_history_limits_and_indexes_are_quarantined
    with_tmp_dir do |dir|
      clock = -> { Time.utc(2026, 8, 30, 12, 0, 0) }
      store = Hive::Proposals::SourceEventStore.new(root: dir, limits: limits, clock:)
      retained = store.send(
        :retained_admissions,
        { "recent_admissions" => [ { "at" => "invalid" }, {},
                                    { "at" => "2026-08-30T12:00:00Z" } ] }
      )
      assert_equal [ { "at" => "2026-08-30T12:00:00Z" } ], retained

      invalid_limit = Hive::Proposals::SourceEventStore.new(
        root: dir, limits: limits.merge("max_project_events" => "many")
      )
      assert_raises(Hive::Proposals::InvalidRecord) do
        invalid_limit.send(:integer_limit, "max_project_events")
      end

      FileUtils.mkdir_p(store.inbox_root)
      File.write(File.join(store.inbox_root, "index.json"), "{}")
      assert_raises(Hive::Proposals::QuarantinedSource) { store.index }

      malformed = store.send(:empty_index).merge("consumed_count" => -1)
      File.write(File.join(store.inbox_root, "index.json"), Hive::Proposals.canonical(malformed))
      assert_raises(Hive::Proposals::QuarantinedSource) { store.index }

      File.write(File.join(store.inbox_root, "index.json"), "{not json")
      assert_raises(Hive::Proposals::QuarantinedSource) { store.index }
    end
  end

  def test_bounded_reads_reject_directories_symlinks_and_growth_after_stat
    with_tmp_dir do |dir|
      store = Hive::Proposals::SourceEventStore.new(root: dir, limits: limits)
      directory = File.join(dir, "directory")
      FileUtils.mkdir_p(directory)
      assert_raises(Hive::Proposals::QuarantinedSource) do
        store.send(:read_bytes, directory, max_bytes: 16)
      end

      symlink = File.join(dir, "symlink")
      File.symlink("missing", symlink)
      assert_raises(Hive::Proposals::QuarantinedSource) do
        store.send(:read_bytes, symlink, max_bytes: 16)
      end

      stat = Struct.new(:file?, :size).new(true, 1)
      fake = Struct.new(:stat, :bytes) do
        def read(_limit) = bytes
      end.new(stat, "x" * 16)
      replacement = ->(*_arguments, **_options, &block) { block.call(fake) }
      with_replaced_singleton_method(File, :open, replacement) do
        assert_raises(Hive::Proposals::QuarantinedSource) do
          store.send(:read_bytes, "fake", max_bytes: 16)
        end
      end
    end
  end

  private

  def source_event
    @source_event ||= Hive::Proposals::SourceEvent.submission(
      source_event_id: "pse-#{'a' * 64}",
      proposal_id: "prp-00000000-0000-4000-8000-000000000001",
      proposal_binding: {
        "schema_version" => 1,
        "subject" => {
          "kind" => "workflow", "reference" => "coding", "revision" => "v2",
          "proposal_id" => "prp-00000000-0000-4000-8000-000000000001"
        },
        "actor" => { "id" => "alice", "kind" => "proposer", "binding" => "team:workflow" },
        "evaluator" => nil, "configuration_fingerprint" => "c" * 64,
        "policy" => {
          "visibility" => "project", "retention" => "project",
          "allowed_link_schemes" => [ "https" ]
        }
      },
      task_binding: {
        "project" => "hive", "task_id" => "43059", "task_slug" => "proposal-task",
        "workflow_id" => "coding", "stage" => "4-execute", "task_generation" => 1,
        "ownership_generation" => "owner-1", "attempt_id" => "attempt-1"
      },
      proposed_change: "Change review", motivation: "Improve quality",
      evidence: [ { "label" => "test", "content" => "pass", "media_type" => "text/plain" } ],
      created_at: "2026-08-30T12:00:00Z"
    )
  end

  def limits
    {
      "max_pending_sources" => 8, "max_project_events" => 100,
      "max_project_bytes" => 1_000_000, "max_sources_per_actor_per_hour" => 10
    }
  end
end
