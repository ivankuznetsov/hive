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

  def test_descriptor_validation_rejects_invalid_requests_and_stage_shapes
    valid = [ stage("inbox", 1, kind: :passive) ]
    error = assert_raises(Hive::WorkLedger::InvalidRequest) do
      Hive::WorkLedger.validate_descriptor(
        identity: "demo",
        stages: valid,
        allowed_kinds: []
      )
    end
    assert_includes error.message, "allowed_kinds"

    invalid = [
      [ [ "not-a-mapping" ], /must be a mapping/ ],
      [ [ stage("", 1, kind: :passive) ], /name must be a non-empty string/ ],
      [ [ stage("inbox", 1, kind: :passive, dir: "") ], /dir must be a non-empty string/ ]
    ]
    invalid.each do |stages, message|
      error = assert_raises(Hive::WorkLedger::InvalidDescriptor) do
        Hive::WorkLedger.validate_descriptor(
          identity: "demo",
          stages: stages,
          allowed_kinds: [ :passive ]
        )
      end
      assert_match message, error.message
    end
  end

  def test_journal_rejects_invalid_construction_and_record_identity
    invalid = [
      { path: "", lock_path: "/tmp/ledger.lock", record_id: ->(record) { record["id"] } },
      { path: "/tmp/ledger", lock_path: "", record_id: ->(record) { record["id"] } },
      { path: "/tmp/ledger", lock_path: "/tmp/ledger.lock", record_id: nil }
    ]
    invalid.each do |arguments|
      assert_raises(Hive::WorkLedger::InvalidRequest) do
        Hive::WorkLedger.journal(**arguments)
      end
    end

    with_tmp_dir do |dir|
      journal = ledger(File.join(dir, "ledger.jsonl"))
      assert_raises(Hive::WorkLedger::InvalidRequest) { journal.append([]) }
      assert_raises(Hive::WorkLedger::InvalidRecord) { journal.append([ record("") ]) }

      strict = Hive::WorkLedger.journal(
        path: File.join(dir, "strict.jsonl"),
        lock_path: File.join(dir, ".strict.lock"),
        record_id: ->(candidate) { candidate.fetch("id") }
      )
      assert_raises(Hive::WorkLedger::InvalidRecord) { strict.append([ {} ]) }
    end
  end

  def test_idempotent_append_validates_callbacks_and_wraps_callback_failures
    with_tmp_dir do |dir|
      journal = ledger(File.join(dir, "ledger.jsonl"))
      invalid = assert_raises(Hive::WorkLedger::InvalidRequest) do
        journal.append_idempotent(
          record("record-1"),
          idempotency_key: "request-1",
          key_for: nil,
          signature_for: ->(candidate) { candidate["value"] }
        )
      end
      assert_includes invalid.message, "key_for"

      journal.append([ record("existing") ])
      failed = assert_raises(Hive::WorkLedger::AppendFailed) do
        journal.append_idempotent(
          record("record-1"),
          idempotency_key: "request-1",
          key_for: ->(_candidate) { raise "callback failed" },
          signature_for: ->(candidate) { candidate["value"] }
        )
      end
      assert_includes failed.message, "RuntimeError: callback failed"
    end
  end

  def test_idempotent_append_rejects_existing_record_without_identity
    with_tmp_dir do |dir|
      path = File.join(dir, "ledger.jsonl")
      File.write(path, "#{JSON.generate(record(nil, key: 'request-1'))}\n")
      journal = ledger(path)

      error = assert_raises(Hive::WorkLedger::InvalidRecord) do
        journal.append_idempotent(
          record("record-1", key: "request-1"),
          idempotency_key: "request-1",
          key_for: ->(candidate) { candidate["key"] },
          signature_for: ->(candidate) { candidate["value"] }
        )
      end
      assert_includes error.message, "identity must be a non-empty string"
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

  def test_idempotent_append_checks_every_existing_record_for_conflicts
    with_tmp_dir do |dir|
      path = File.join(dir, "ledger.jsonl")
      existing = [
        record("record-1", key: "request-1", value: "same"),
        record("record-2", key: "request-1", value: "different")
      ]
      File.write(path, existing.map { |candidate| JSON.generate(candidate) }.join("\n") + "\n")
      journal = ledger(path)

      error = assert_raises(Hive::WorkLedger::Conflict) do
        journal.append_idempotent(
          record("record-3", key: "request-1", value: "same"),
          idempotency_key: "request-1",
          key_for: ->(candidate) { candidate["key"] },
          signature_for: ->(candidate) { candidate["value"] }
        )
      end

      assert_includes error.message, "request-1"
      assert_equal 2, File.readlines(path).size
    end
  end

  def test_receipts_are_deeply_immutable_copies_of_caller_values
    with_tmp_dir do |dir|
      id = +"record-1"
      nested = +"original"
      input = { "id" => id, "nested" => [ nested ] }
      append = ledger(File.join(dir, "ledger.jsonl")).append([ input ])
      id.replace("changed")
      nested.replace("changed")
      input["extra"] = true

      assert_equal "record-1", append.record_id
      assert_equal(
        [ { "id" => "record-1", "nested" => [ "original" ] } ],
        append.records
      )
      assert_predicate append.record_id, :frozen?
      assert_predicate append.ledger_hash, :frozen?
      assert_predicate append.records, :frozen?
      assert_predicate append.records.first, :frozen?
      assert_predicate append.records.first.fetch("nested"), :frozen?
      assert_predicate append.records.first.fetch("nested").first, :frozen?
    end

    identity = +"demo"
    names = [ +"inbox" ]
    dirs = [ +"1-inbox" ]
    descriptor = Hive::WorkLedger::DescriptorReceipt.new(
      identity: identity, stage_names: names, stage_dirs: dirs
    )
    identity.replace("changed")
    names.first.replace("changed")
    dirs.first.replace("changed")
    assert_equal "demo", descriptor.identity
    assert_equal [ "inbox" ], descriptor.stage_names
    assert_equal [ "1-inbox" ], descriptor.stage_dirs
    assert_predicate descriptor.identity, :frozen?
    assert_predicate descriptor.stage_names.first, :frozen?
    assert_predicate descriptor.stage_dirs.first, :frozen?
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
    original_bytes = bytes.dup
    validated = []
    replacement = nil

    receipt = Hive::WorkLedger.replay(
      bytes: bytes,
      record_id: ->(candidate) { candidate["id"] }
    ) do |candidate, line_number|
      validated << [ candidate.fetch("id"), line_number ]
      bytes.replace("{}\n") if line_number == 1
      replacement = candidate.merge("validated" => true, "nested" => [ +"original" ])
    end

    replacement.fetch("nested").first.replace("changed")
    assert_equal [ [ "record-1", 1 ], [ "record-2", 2 ] ], validated
    assert_equal original_bytes.bytesize, receipt.cursor
    assert_equal Digest::SHA256.hexdigest(original_bytes), receipt.ledger_hash
    assert_equal "record-2", receipt.record_id
    assert receipt.records.all? { |candidate| candidate["validated"] }
    assert_equal "original", receipt.records.last.dig("nested", 0)
    assert_predicate receipt.record_id, :frozen?
    assert_predicate receipt.ledger_hash, :frozen?
    assert_predicate receipt.records, :frozen?
    assert_predicate receipt.records.last, :frozen?
    assert_predicate receipt.records.last.fetch("nested"), :frozen?
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

  def test_replay_validates_callbacks_and_wraps_unexpected_failures
    assert_raises(Hive::WorkLedger::InvalidRequest) do
      Hive::WorkLedger::Replay.call(
        bytes: "",
        record_id: ->(candidate) { candidate["id"] },
        source_label: "ledger",
        record_label: "record_id",
        validator: Object.new
      )
    end

    error = assert_raises(Hive::WorkLedger::ReplayFailed) do
      Hive::WorkLedger.replay(
        bytes: "#{JSON.generate(record('record-1'))}\n",
        record_id: ->(_candidate) { raise "identity failed" }
      )
    end
    assert_includes error.message, "RuntimeError: identity failed"
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
