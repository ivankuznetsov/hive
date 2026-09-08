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
        root: dir, limits: limits.merge("max_proposal_events" => 2)
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
      assert_equal 2, store.index.dig("usage", "project_events")
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

  def test_admission_reserves_terminal_and_canonical_capacity_at_the_byte_ceiling
    with_tmp_dir do |dir|
      store = Hive::Proposals::SourceEventStore.new(root: dir, limits: limits)
      store.admit!(source_event)
      usage = store.send(:namespace_usage_unlocked, store.index)
      store.instance_variable_get(:@limits)["max_project_bytes"] =
        usage.fetch("project_bytes") + usage.fetch("reserved_bytes")

      status = store.mark_consumed!(
        source_event.source_event_id,
        result: { "kind" => "record", "proposal_id" => source_event.proposal_id,
                  "event_id" => nil, "source_event_id" => source_event.source_event_id }
      )

      assert_equal "consumed", status.fetch("state")
      assert_empty store.pending_ids
    end
  end

  def test_aggregate_quotas_cover_sources_canonical_files_and_lifecycle_authorities
    quota_cases = [
      [ { "max_project_events" => 1 }, /project event quota/ ],
      [ { "max_project_bytes" => 1 }, /project byte quota/ ],
      [ { "max_proposal_bytes" => 1 }, /proposal byte quota/ ]
    ]
    quota_cases.each do |overrides, message|
      with_tmp_dir do |dir|
        store = Hive::Proposals::SourceEventStore.new(
          root: dir, limits: limits.merge(overrides)
        )
        error = assert_raises(Hive::Proposals::QuotaExceeded) { store.admit!(source_event) }
        assert_match message, error.message
      end
    end

    with_tmp_dir do |dir|
      store = Hive::Proposals::SourceEventStore.new(
        root: dir, limits: limits.merge("max_sources_per_actor_per_hour" => 1),
        clock: -> { Time.utc(2026, 8, 30, 12, 30, 0) }
      )
      store.admit!(source_event)
      error = assert_raises(Hive::Proposals::QuotaExceeded) do
        store.enforce_lifecycle!(proposal_id: source_event.proposal_id, actor_id: "alice", event_bytes: 1)
      end
      assert_match(/rate limit/, error.message)
    end

    with_tmp_dir do |dir|
      record_dir = File.join(dir, "records")
      FileUtils.mkdir_p(record_dir)
      File.binwrite(File.join(record_dir, "#{source_event.proposal_id}.json"), "{}")
      store = Hive::Proposals::SourceEventStore.new(
        root: dir, limits: limits.merge("max_project_events" => 1)
      )
      assert_raises(Hive::Proposals::QuotaExceeded) do
        store.enforce_lifecycle!(proposal_id: source_event.proposal_id, actor_id: "operator", event_bytes: 1)
      end
    end
  end

  def test_invalid_limits_and_indexes_are_quarantined
    with_tmp_dir do |dir|
      store = Hive::Proposals::SourceEventStore.new(root: dir, limits: limits)

      assert_raises(Hive::Proposals::InvalidRecord) do
        store.enforce_lifecycle!(
          proposal_id: source_event.proposal_id, actor_id: "operator", event_bytes: "many"
        )
      end

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

  def test_terminal_status_cannot_exceed_its_reservation
    with_tmp_dir do |dir|
      store = Hive::Proposals::SourceEventStore.new(root: dir, limits: limits)
      store.admit!(source_event)

      assert_raises(Hive::Proposals::Error) do
        store.mark_consumed!(
          source_event.source_event_id,
          result: { "details" => "x" * Hive::Proposals::SourceEventStore::MAX_TERMINAL_BYTES }
        )
      end
      assert_equal "pending", store.status(source_event.source_event_id).fetch("state")
    end
  end

  def test_namespace_usage_tolerates_symlinks_and_disappearing_paths
    with_tmp_dir do |dir|
      store = Hive::Proposals::SourceEventStore.new(root: dir, limits: limits)
      FileUtils.mkdir_p(File.join(dir, "records"))
      symlink = File.join(dir, "records", "linked.json")
      File.symlink("missing.json", symlink)
      store.send(:namespace_usage_unlocked, store.send(:empty_index))

      original_lstat = File.method(:lstat)
      directory_symlink = Struct.new(:symlink?, :directory?).new(true, true)
      replacement = lambda do |path|
        path == symlink ? directory_symlink : original_lstat.call(path)
      end
      with_replaced_singleton_method(File, :lstat, replacement) do
        store.send(:namespace_usage_unlocked, store.send(:empty_index))
      end

      vanishing = File.join(dir, "records", "vanishing.json")
      File.write(vanishing, "{}")
      replacement = lambda do |path|
        raise Errno::ENOENT if path == vanishing
        original_lstat.call(path)
      end
      usage = with_replaced_singleton_method(File, :lstat, replacement) do
        store.send(:namespace_usage_unlocked, store.send(:empty_index))
      end
      assert_equal 0, usage.fetch("project_events")
    end
  end

  def test_malformed_namespace_entries_are_ignored_by_quota_accounting
    with_tmp_dir do |dir|
      store = Hive::Proposals::SourceEventStore.new(root: dir, limits: limits)
      FileUtils.mkdir_p(store.inbox_root)
      receipt_path = File.join(store.inbox_root, "#{source_event.source_event_id}.json")
      File.write(receipt_path, "{malformed")

      assert_nil store.send(
        :proposal_id_for_file, "inbox/#{source_event.source_event_id}.json", receipt_path
      )

      event_dir = File.join(dir, "events", source_event.proposal_id)
      FileUtils.mkdir_p(event_dir)
      File.write(File.join(event_dir, "malformed.json"), "[]")
      File.write(File.join(event_dir, "also-malformed.json"), "null")
      assert_equal 0, store.send(:recent_actor_events_unlocked, "alice")

      store.send(:write_index_unlocked, store.send(:empty_index))
      assert_equal [], store.index.fetch("pending")
      assert_equal 3, store.index.dig("usage", "project_events")
      assert_operator store.index.dig("usage", "project_bytes"), :>, 0

      assert_raises(Hive::Proposals::QuarantinedSource) do
        store.fetch(source_event.source_event_id)
      end
    end
  end

  def test_admission_and_rate_checks_do_not_rescan_retained_history
    with_tmp_dir do |dir|
      store = Hive::Proposals::SourceEventStore.new(root: dir, limits: limits)
      store.admit!(source_event)
      replacement = ->(*_arguments) { raise "retained history scan" }

      with_replaced_singleton_method(Find, :find, replacement) do
        second = Hive::Proposals::SourceEvent.new(
          source_event.to_h.merge("source_event_id" => "pse-#{'d' * 64}")
        )
        store.admit!(second)
        assert_equal 2, store.send(:recent_actor_events_unlocked, "alice")
      end
    end
  end


  def test_persisted_usage_and_rate_window_survive_restart_without_history_scans
    with_tmp_dir do |dir|
      now = Time.utc(2026, 8, 30, 12, 30, 0)
      clock = -> { now }
      store = Hive::Proposals::SourceEventStore.new(root: dir, limits: limits, clock:)
      store.admit!(source_event)
      before = store.index.fetch("usage")
      restarted = Hive::Proposals::SourceEventStore.new(root: dir, limits: limits, clock:)
      replacement = ->(*_arguments) { raise "retained history scan" }

      with_replaced_singleton_method(Find, :find, replacement) do
        assert_equal before, restarted.index.fetch("usage")
        second = Hive::Proposals::SourceEvent.new(
          source_event.to_h.merge("source_event_id" => "pse-#{'d' * 64}")
        )
        restarted.admit!(second)
        assert_equal 2, restarted.send(:recent_actor_events_unlocked, "alice")
        now += 3_601
        assert_equal 0, restarted.send(:recent_actor_events_unlocked, "alice")
      end
    end
  end

  def test_absent_index_bootstraps_inbox_canonical_and_rate_accounting_with_malformed_neighbors
    with_tmp_dir do |dir|
      inbox = File.join(dir, "inbox")
      quarantine = File.join(inbox, "quarantine")
      event_dir = File.join(dir, "events", source_event.proposal_id)
      FileUtils.mkdir_p(quarantine)
      FileUtils.mkdir_p(event_dir)
      receipt = Hive::Proposals.canonical(source_event.to_h)
      status = Hive::Proposals.canonical(
        "schema" => "hive-proposal-source-status", "schema_version" => 1,
        "source_event_id" => source_event.source_event_id,
        "proposal_id" => source_event.proposal_id, "state" => "quarantine",
        "result" => nil, "reason" => { "code" => "invalid", "message" => "invalid" },
        "recorded_at" => "2026-08-30T12:10:00.000000Z"
      )
      receipt_path = File.join(inbox, "#{source_event.source_event_id}.json")
      status_path = File.join(quarantine, "#{source_event.source_event_id}.json")
      array_path = File.join(event_dir, "00000000000000000001-array.json")
      null_path = File.join(event_dir, "00000000000000000002-null.json")
      File.binwrite(receipt_path, receipt)
      File.binwrite(status_path, status)
      File.binwrite(array_path, "[]")
      File.binwrite(null_path, "null")
      store = Hive::Proposals::SourceEventStore.new(
        root: dir, limits: limits, clock: -> { Time.utc(2026, 8, 30, 12, 30, 0) }
      )

      index = store.index

      assert_equal 3, index.dig("usage", "project_events")
      assert_equal [ receipt, status, "[]", "null" ].sum(&:bytesize),
                   index.dig("usage", "project_bytes")
      assert_equal index.dig("usage", "project_bytes"),
                   index.dig("usage", "proposals", source_event.proposal_id, "bytes")
      assert_equal 1, store.send(:recent_actor_events_unlocked, "alice", index)
    end
  end

  def test_oversize_index_is_rejected_before_the_new_receipt_is_written
    with_tmp_dir do |dir|
      store = Hive::Proposals::SourceEventStore.new(
        root: dir, limits: limits.merge("max_pending_sources" => 10_000)
      )
      index = store.send(:empty_index)
      sequence = 0
      loop do
        sequence += 1
        id = "pse-#{Digest::SHA256.hexdigest(sequence.to_s)}"
        candidate = Hive::Proposals.stringify(index)
        candidate["pending"] << id
        candidate["pending_proposals"][id] = source_event.proposal_id
        candidate["reservations"][id] = { "bytes" => 1, "events" => 1 }
        candidate["total_sources"] += 1
        break if Hive::Proposals.canonical(candidate).bytesize >
                 Hive::Proposals::SourceEventStore::MAX_FILE_BYTES
        index = candidate
      end
      FileUtils.mkdir_p(store.inbox_root)
      File.binwrite(File.join(store.inbox_root, "index.json"), Hive::Proposals.canonical(index))

      assert_raises(Hive::Proposals::QuotaExceeded) { store.admit!(source_event) }
      refute File.exist?(File.join(store.inbox_root, "#{source_event.source_event_id}.json"))
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
        assert_equal "x" * 16, store.send(:read_bytes, "fake", max_bytes: 16)
      end

      fake.bytes = "x" * 17
      with_replaced_singleton_method(File, :open, replacement) do
        assert_raises(Hive::Proposals::QuarantinedSource) do
          store.send(:read_bytes, "fake", max_bytes: 16)
        end
      end
    end
  end

  def test_inbox_and_terminal_writes_reject_symlinked_parent_directories
    with_tmp_dir do |dir|
      outside = Dir.mktmpdir("proposal-source-outside")
      begin
        File.symlink(outside, File.join(dir, "inbox"))
        store = Hive::Proposals::SourceEventStore.new(root: dir, limits: limits)

        assert_raises(Hive::Proposals::Error) { store.admit!(source_event) }
        assert_empty Dir.children(outside)
      ensure
        FileUtils.rm_rf(outside)
      end
    end

    with_tmp_dir do |dir|
      store = Hive::Proposals::SourceEventStore.new(root: dir, limits: limits)
      store.admit!(source_event)
      outside = Dir.mktmpdir("proposal-status-outside")
      begin
        File.symlink(outside, File.join(store.inbox_root, "consumed"))

        assert_raises(Hive::Proposals::Error) do
          store.mark_consumed!(source_event.source_event_id, result: { "proposal_id" => source_event.proposal_id })
        end
        assert_empty Dir.children(outside)
      ensure
        FileUtils.rm_rf(outside)
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
