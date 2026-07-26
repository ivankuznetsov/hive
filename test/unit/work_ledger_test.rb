require "test_helper"
require "open3"
require "rbconfig"
require "hive/work_ledger"

class WorkLedgerTest < Minitest::Test
  include HiveTestHelper

  def test_clean_entrypoint_does_not_load_hive_policy_or_runtime
    script = <<~'RUBY'
      require "hive/work_ledger"

      forbidden = $LOADED_FEATURES.grep(
        %r{/hive/(?:attempts|conditions|task_journal|task_projection|workflow|workflows)(?:/|\.rb)}
      )
      abort forbidden.join("\n") unless forbidden.empty?
      abort "missing facade" unless defined?(Hive::WorkLedger)
    RUBY

    _out, err, status = Open3.capture3(
      RbConfig.ruby, "-Ilib", "-e", script, chdir: File.expand_path("../..", __dir__)
    )

    assert status.success?, err
  end

  def test_descriptor_validation_is_structural_and_returns_an_immutable_receipt
    stages = [
      stage("inbox", 1, kind: :passive),
      stage("work", 2, kind: :producer, advance_verb: "work")
    ]

    receipt = Hive::WorkLedger.validate_descriptor(
      identity: "demo",
      stages: stages,
      allowed_kinds: [ :passive, :producer ]
    )

    assert_equal "demo", receipt.identity
    assert_equal %w[inbox work], receipt.stage_names
    assert_equal %w[1-inbox 2-work], receipt.stage_dirs
    assert receipt.frozen?
    assert receipt.stage_names.frozen?
    assert_raises(FrozenError) { receipt.stage_names << "done" }
  end

  def test_descriptor_validation_rejects_malformed_identity_and_topology
    valid = [
      stage("inbox", 1, kind: :passive),
      stage("work", 2, kind: :producer, advance_verb: "work")
    ]
    invalid = [
      [ { identity: "", stages: valid }, /identity/ ],
      [ { identity: "demo", stages: [] }, /at least one stage/ ],
      [ { identity: "demo", stages: [
        stage("inbox", 1, kind: :passive),
        stage("work", 3, kind: :producer, advance_verb: "work")
      ] }, /stage indices/ ],
      [ { identity: "demo", stages: [
        stage("same", 1, kind: :passive),
        stage("same", 2, kind: :producer, advance_verb: "work")
      ] }, /duplicate stage names/ ],
      [ { identity: "demo", stages: [
        stage("inbox", 1, kind: :passive, dir: "same"),
        stage("work", 2, kind: :producer, advance_verb: "work", dir: "same")
      ] }, /duplicate stage dirs/ ],
      [ { identity: "demo", stages: [
        stage("inbox", 1, kind: :unknown)
      ] }, /unknown kind/ ],
      [ { identity: "demo", stages: [
        stage("inbox", 1, kind: :passive, advance_verb: "start")
      ] }, /first stage/ ]
    ]

    invalid.each do |arguments, message|
      error = assert_raises(Hive::WorkLedger::InvalidDescriptor) do
        Hive::WorkLedger.validate_descriptor(
          **arguments,
          allowed_kinds: [ :passive, :producer ]
        )
      end
      assert_match message, error.message
    end
  end

  def test_journal_append_is_durable_and_idempotent_with_conflicts_fail_closed
    with_tmp_dir do |dir|
      path = File.join(dir, "ledger.jsonl")
      journal = ledger(path)
      first = record("record-1", key: "request-1", value: "same")

      assert_instance_of Hive::WorkLedger::JournalHandle, journal
      receipt = journal.append([ first ])
      assert_equal File.size(path), receipt.cursor
      assert_equal "record-1", receipt.record_id
      assert_equal Digest::SHA256.file(path).hexdigest, receipt.ledger_hash

      duplicate = journal.append_idempotent(
        record("record-2", key: "request-1", value: "same"),
        idempotency_key: "request-1",
        key_for: ->(candidate) { candidate["key"] },
        signature_for: ->(candidate) { candidate["value"] }
      )
      assert_equal "record-1", duplicate.record_id
      assert_equal 1, File.readlines(path).size

      error = assert_raises(Hive::WorkLedger::Conflict) do
        journal.append_idempotent(
          record("record-3", key: "request-1", value: "different"),
          idempotency_key: "request-1",
          key_for: ->(candidate) { candidate["key"] },
          signature_for: ->(candidate) { candidate["value"] }
        )
      end
      assert_includes error.message, "request-1"
      assert_equal 1, File.readlines(path).size
    end
  end

  def test_append_waits_for_the_named_exclusive_lock
    with_tmp_dir do |dir|
      path = File.join(dir, "ledger.jsonl")
      lock_path = File.join(dir, ".ledger.lock")
      journal = Hive::WorkLedger.journal(
        path: path,
        lock_path: lock_path,
        record_id: ->(candidate) { candidate["id"] }
      )
      started = Queue.new

      File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |lock|
        lock.flock(File::LOCK_EX)
        worker = Thread.new do
          started << true
          journal.append([ record("record-1") ])
        end
        started.pop
        sleep 0.05
        assert worker.alive?, "append must wait while another owner holds the ledger lock"
        refute File.exist?(path)
        lock.flock(File::LOCK_UN)
        worker.join
      end

      assert_equal "record-1", JSON.parse(File.binread(path)).fetch("id")
    end
  end

  def test_partial_append_failure_rolls_back_to_last_durable_record
    with_tmp_dir do |dir|
      path = File.join(dir, "ledger.jsonl")
      journal = ledger(path)
      journal.append([ record("record-1") ])
      before = File.binread(path)
      original_open = File.method(:open)
      replacement = lambda do |opened_path, *args, **kwargs, &block|
        unless opened_path == path && block
          next original_open.call(opened_path, *args, **kwargs, &block)
        end

        original_open.call(opened_path, *args, **kwargs) do |file|
          syswrite = file.method(:syswrite)
          calls = 0
          file.define_singleton_method(:syswrite) do |bytes|
            calls += 1
            raise Errno::ENOSPC if calls > 1

            syswrite.call(bytes.byteslice(0, 9))
          end
          block.call(file)
        end
      end

      with_replaced_singleton_method(File, :open, replacement) do
        assert_raises(Hive::WorkLedger::AppendFailed) do
          journal.append([ record("record-2") ])
        end
      end
      assert_equal before, File.binread(path)
    end
  end

  def test_replay_decodes_validates_and_binds_exact_bytes
    bytes = [
      JSON.generate(record("record-1")),
      JSON.generate(record("record-2"))
    ].join("\n") + "\n"
    validated = []

    receipt = Hive::WorkLedger.replay(
      bytes: bytes,
      record_id: ->(candidate) { candidate["id"] }
    ) do |candidate, line_number|
      validated << [ candidate.fetch("id"), line_number ]
      candidate.merge("validated" => true)
    end

    assert_equal [ [ "record-1", 1 ], [ "record-2", 2 ] ], validated
    assert_equal bytes.bytesize, receipt.cursor
    assert_equal Digest::SHA256.hexdigest(bytes), receipt.ledger_hash
    assert_equal "record-2", receipt.record_id
    assert receipt.records.all? { |candidate| candidate["validated"] }
  end

  def test_replay_rejects_invalid_json_and_duplicate_record_identity
    malformed = assert_raises(Hive::WorkLedger::InvalidRecord) do
      Hive::WorkLedger.replay(
        bytes: "#{JSON.generate(record('record-1'))}\nnot-json\n",
        record_id: ->(candidate) { candidate["id"] }
      )
    end
    assert_includes malformed.message, "ledger line 2"

    bytes = [
      JSON.generate(record("same")),
      JSON.generate(record("same"))
    ].join("\n") + "\n"
    duplicate = assert_raises(Hive::WorkLedger::InvalidRecord) do
      Hive::WorkLedger.replay(
        bytes: bytes,
        record_id: ->(candidate) { candidate["id"] }
      )
    end
    assert_includes duplicate.message, "duplicate record_id"
    assert_includes duplicate.message, "line 2"

    missing = assert_raises(Hive::WorkLedger::InvalidRecord) do
      Hive::WorkLedger.replay(
        bytes: "{}\n",
        record_id: ->(candidate) { candidate["id"] }
      )
    end
    assert_includes missing.message, "record_id must be a non-empty string"
  end

  private

  def ledger(path)
    Hive::WorkLedger.journal(
      path: path,
      lock_path: File.join(File.dirname(path), ".ledger.lock"),
      record_id: ->(candidate) { candidate["id"] }
    )
  end

  def record(id, key: nil, value: "value")
    { "id" => id, "key" => key, "value" => value }
  end

  def stage(name, index, kind:, advance_verb: nil, dir: nil)
    {
      name: name,
      index: index,
      dir: dir || "#{index}-#{name}",
      kind: kind,
      advance_verb: advance_verb
    }
  end
end
