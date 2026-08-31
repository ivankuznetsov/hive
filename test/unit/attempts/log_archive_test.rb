require "test_helper"
require "hive/attempts/log_archive"

class AttemptsLogArchiveTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 8, 10, 12, 0, 0)
  CAPABILITY = "c" * 64

  def test_writer_and_reader_custody_block_content_addressed_publication
    with_repository do |store|
      running = running_attempt(store)
      archive = store.log_archive
      writer = archive.open_writer(running.attempt_id, clock: -> { NOW })
      writer.append(:stdout, "open\n")

      assert_equal :busy, archive.archive(running.attempt_id)
      writer.close
      terminal = terminalize(store, running)

      reader_entered = Queue.new
      release_reader = Queue.new
      reader = Thread.new do
        archive.with_reader(terminal.attempt_id) do |_path, availability|
          reader_entered << availability
          release_reader.pop
        end
      end
      assert_equal :available, reader_entered.pop
      assert_equal :busy, archive.archive(terminal.attempt_id)
      release_reader << true
      reader.join

      assert_equal :archived, archive.archive(terminal.attempt_id)
      refute File.exist?(archive.hot_path(terminal.attempt_id))
      resolved = archive.resolve(terminal.attempt_id)
      assert_equal :available, resolved.availability
      assert_includes resolved.path, "/sealed/sha256/"
      assert_equal [ "open\n" ], archive.read(terminal.attempt_id).frames.map(&:bytes)
    ensure
      writer&.close unless writer&.closed?
      release_reader << true if reader&.alive?
      reader&.join
    end
  end

  def test_terminal_log_and_outputs_seal_once_with_canonical_sql_references
    with_repository do |store|
      running = running_attempt(store)
      log_reference = write_log(store, running.attempt_id, "done\n")
      output_path = store.output_path(running.attempt_id, "result.json", create_directory: true)
      File.binwrite(output_path, "{\"ok\":true}")
      output_reference = Hive::OutputReference.build(output_path, root: store.root)
      terminal = terminalize(
        store, running,
        log_reference: log_reference,
        output_references: [ output_reference ]
      )

      assert_equal :archived, store.log_archive.archive(terminal.attempt_id)
      assert_equal :archived, store.log_archive.archive(terminal.attempt_id)
      rows = store.database.read do |db|
        db[:payload_references].where(attempt_id: terminal.attempt_id).order(:kind).all
      end
      assert_equal %w[attempt_log attempt_output], rows.map { |row| row.fetch(:kind) }
      rows.each do |row|
        assert_equal "sealed", row.fetch(:state)
        assert_match(%r{\Asealed/sha256/[0-9a-f]{2}/[0-9a-f]{64}\z}, row.fetch(:relative_path))
        assert_equal row.fetch(:sha256), File.basename(row.fetch(:relative_path))
      end
      refute File.exist?(output_path)
      assert_equal "{\"ok\":true}", store.read_output(output_reference, max_bytes: 64)
    end
  end

  def test_expected_digest_and_size_are_proven_before_publication
    with_repository do |store|
      running = running_attempt(store)
      log_reference = write_log(store, running.attempt_id, "original\n")
      terminal = terminalize(store, running, log_reference: log_reference)
      File.binwrite(store.log_archive.hot_path(terminal.attempt_id), "tampered\n")

      error = assert_raises(Hive::Attempts::RepositoryError) do
        store.log_archive.archive(terminal.attempt_id)
      end
      assert_match(/digest differs|size differs/, error.message)
      assert_empty store.database.read { |db| db[:payload_references].all }
      assert File.file?(store.log_archive.hot_path(terminal.attempt_id))
    end
  end

  def test_missing_or_corrupt_sealed_payloads_fail_closed
    with_repository do |store|
      missing = running_attempt(store, attempt_id: "missing", request_id: "missing-request")
      missing_reference = {
        "path" => "open/missing.frames", "size" => 0,
        "sha256" => Digest::SHA256.hexdigest("")
      }
      missing = terminalize(store, missing, log_reference: missing_reference)
      error = assert_raises(Hive::Attempts::RepositoryError) do
        store.log_archive.archive(missing.attempt_id)
      end
      assert_match(/payload sealing failed/, error.message)

      running = running_attempt(store, attempt_id: "corrupt", request_id: "corrupt-request")
      reference = write_log(store, running.attempt_id, "sealed\n")
      terminal = terminalize(store, running, log_reference: reference)
      assert_equal :archived, store.log_archive.archive(terminal.attempt_id)
      sealed = store.log_archive.resolve(terminal.attempt_id).path
      bytes = File.binread(sealed)
      File.binwrite(sealed, "x" * bytes.bytesize)

      error = assert_raises(Hive::Attempts::RepositoryError) do
        store.log_archive.archive(terminal.attempt_id)
      end
      assert_match(/digest does not match/, error.message)
      assert_raises(Hive::Attempts::RepositoryError) do
        store.log_archive.resolve(terminal.attempt_id)
      end
    end
  end

  def test_sql_page_is_bounded_resumable_and_expiry_preserves_shared_bytes
    with_repository do |store|
      %w[a b c].each do |attempt_id|
        running = running_attempt(
          store, attempt_id: attempt_id, request_id: "request-#{attempt_id}"
        )
        reference = write_log(store, attempt_id, "same\n")
        terminal = terminalize(store, running, log_reference: reference)
        assert_equal :archived, store.log_archive.archive(terminal.attempt_id)
      end

      first = store.log_archive.cold_attempt_ids_page(cursor: { "after" => nil }, limit: 2)
      second = store.log_archive.cold_attempt_ids_page(cursor: first.cursor, limit: 2)
      assert_equal 2, first.attempt_ids.size
      assert_equal 2, second.attempt_ids.size
      assert_empty(%w[a b c] - (first.attempt_ids + second.attempt_ids))

      assert_equal :expired, store.log_archive.expire("a", now: NOW + 60)
      assert_equal :expired, store.log_archive.resolve("a").availability
      assert_equal :available, store.log_archive.resolve("b").availability
    end
  end

  def test_expiry_resumes_after_interruption_between_sql_and_unlink
    with_repository do |store|
      running = running_attempt(store)
      terminal = terminalize(
        store, running, log_reference: write_log(store, running.attempt_id, "expire\n")
      )
      assert_equal :archived, store.log_archive.archive(terminal.attempt_id)
      path = store.log_archive.resolve(terminal.attempt_id).path
      payloads = store.payload_store
      original = payloads.method(:with_reference_custody)
      payloads.define_singleton_method(:with_reference_custody) do |*_args|
        raise IOError, "interrupted"
      end

      assert_raises(Hive::Attempts::RepositoryError) do
        store.log_archive.expire(terminal.attempt_id, now: NOW + 60)
      end
      assert File.file?(path)
      assert_includes store.log_archive.cold_attempt_ids_page(
        cursor: { "after" => nil }, limit: 10
      ).attempt_ids, terminal.attempt_id

      payloads.define_singleton_method(:with_reference_custody, original)
      assert_equal :expired, store.log_archive.expire(terminal.attempt_id, now: NOW + 61)
      refute File.exist?(path)
      retain_until = store.database.read do |db|
        db[:payload_references].where(attempt_id: terminal.attempt_id).get(:retain_until)
      end
      assert_nil retain_until
    end
  end

  def test_shared_digest_expiry_cannot_unlink_between_publication_and_sql_reference
    with_repository do |store|
      first = running_attempt(store, attempt_id: "first", request_id: "first-request")
      first = terminalize(store, first, log_reference: write_log(store, "first", "same\n"))
      assert_equal :archived, store.log_archive.archive(first.attempt_id)

      second = running_attempt(store, attempt_id: "second", request_id: "second-request")
      second = terminalize(store, second, log_reference: write_log(store, "second", "same\n"))
      payloads = store.payload_store
      expiry_checked = Queue.new
      release_expiry = Queue.new
      publisher_waiting = Queue.new
      original_path_for = payloads.method(:path_for)
      original_custody = payloads.method(:with_reference_custody)
      payloads.define_singleton_method(:path_for) do |reference|
        if Thread.current.thread_variable_get(:expiry_race)
          expiry_checked << true
          release_expiry.pop
        end
        original_path_for.call(reference)
      end
      payloads.define_singleton_method(:with_reference_custody) do |references, &block|
        publisher_waiting << true if Thread.current.thread_variable_get(:publisher_race)
        original_custody.call(references, &block)
      end

      expiry = Thread.new do
        Thread.current.thread_variable_set(:expiry_race, true)
        store.log_archive.expire(first.attempt_id, now: NOW + 60)
      end
      expiry_checked.pop
      publisher = Thread.new do
        Thread.current.thread_variable_set(:publisher_race, true)
        store.log_archive.archive(second.attempt_id)
      end
      publisher_waiting.pop
      assert_nil(store.database.read do |db|
        db[:payload_references].where(attempt_id: second.attempt_id).first
      end)

      release_expiry << true
      assert_equal :expired, expiry.value
      assert_equal :archived, publisher.value
      assert_equal :expired, store.log_archive.resolve(first.attempt_id).availability
      assert_equal :available, store.log_archive.resolve(second.attempt_id).availability
      assert_equal [ "same\n" ], store.log_archive.read(second.attempt_id).frames.map(&:bytes)
    ensure
      release_expiry << true if expiry&.alive?
      expiry&.join
      publisher&.join
    end
  end

  def test_unsafe_ids_and_custody_lock_symlinks_fail_closed
    with_repository do |store|
      archive = store.log_archive
      assert_raises(Hive::Attempts::RepositoryError) { archive.resolve("../escape") }

      lock_path = custody_lock_path(store, "attempt-1")
      outside = File.join(File.dirname(store.root), "outside.lock")
      File.write(outside, "")
      File.symlink(outside, lock_path)
      error = assert_raises(Hive::Attempts::RepositoryError) do
        archive.resolve("attempt-1")
      end
      assert_match(/custody lock is a symlink/, error.message)
    end
  end

  def test_writer_archive_page_and_cursor_failures_are_typed
    with_repository do |store|
      archive = store.log_archive
      with_replaced_singleton_method(
        Hive::Attempts::StreamLog, :new, ->(*) { raise IOError, "bad writer" }
      ) do
        assert_raises(IOError) { archive.open_writer("attempt") }
      end

      running = running_attempt(store)
      assert_raises(Hive::Attempts::RepositoryError) { archive.archive(running.attempt_id) }
      assert_raises(Hive::Attempts::RepositoryError) do
        archive.cold_attempt_ids_page(cursor: { "after" => nil }, limit: "bad")
      end
      assert_raises(Hive::Attempts::RepositoryError) do
        archive.cold_attempt_ids_page(cursor: { "after" => "", "extra" => true }, limit: 1)
      end
      assert_raises(Hive::Attempts::RepositoryError) do
        archive.cold_attempt_ids_page(cursor: Object.new, limit: 1)
      end
    end

    with_repository do |store|
      store.database.define_singleton_method(:read) do |**|
        raise Hive::RuntimeControlPlane::IntegrityError.new("bad", code: :database_corrupt)
      end
      assert_raises(Hive::Attempts::RepositoryError) do
        store.log_archive.cold_attempt_ids_page(cursor: { "after" => nil }, limit: 1)
      end
    end
  end

  def test_unknown_sealed_state_missing_byte_and_unsafe_lock_are_bounded
    with_repository do |store|
      running = running_attempt(store)
      terminal = terminalize(
        store, running, log_reference: write_log(store, running.attempt_id, "sealed\n")
      )
      assert_equal :archived, store.log_archive.archive(terminal.attempt_id)
      store.database.transaction do |db|
        db.run("PRAGMA ignore_check_constraints = ON")
        db[:payload_references].where(attempt_id: terminal.attempt_id).update(state: "unknown")
      end
      assert_equal :unavailable, store.log_archive.resolve(terminal.attempt_id).availability

      reference = {
        "algorithm" => "sha256", "sha256" => "a" * 64, "size" => 1,
        "path" => "sealed/sha256/aa/#{'a' * 64}"
      }
      assert_nil store.log_archive.send(:remove_unreferenced, reference)

      fake_status = Struct.new(:dev, :ino) do
        def file? = false
        def symlink? = false
      end.new(1, 1)
      original_lstat = File.method(:lstat)
      with_replaced_singleton_method(
        File, :lstat, ->(path) { path.end_with?(".lock") ? fake_status : original_lstat.call(path) }
      ) do
        assert_raises(Hive::Attempts::RepositoryError) do
          store.log_archive.resolve("unsafe-lock")
        end
      end
    end
  end

  private

  def with_repository
    with_tmp_dir do |root|
      yield Hive::Attempts::Repository.new(root: root, migrate: true)
    end
  end

  def running_attempt(store, attempt_id: "attempt-1", request_id: "request-1")
    launching = store.create_launching(
      attempt_id: attempt_id, request_id: request_id, predecessor_attempt_id: nil,
      task_id: "42", project: "demo", task_slug: "task-#{attempt_id}",
      intended_stage: "4-execute", task_generation: "generation-#{attempt_id}",
      ownership_generation: "owner-#{attempt_id}", task_input_epoch: 1,
      progress_token: "progress-#{attempt_id}", provider: "codex",
      worker_argv: [ "hive", "run", "task" ],
      claim_capability_digest: Hive::Attempts::Capability.digest(CAPABILITY),
      starting_revision: nil, retry_charge: 0, inherited_outputs: [],
      launch_timeout_sec: 30, now: NOW
    )
    claimed = store.claim(
      launching, owner: { "pid" => Process.pid }, claim_capability: CAPABILITY,
      first_heartbeat_timeout_sec: 30, now: NOW + 1
    )
    store.first_heartbeat(claimed, stale_sec: 30, now: NOW + 2)
  end

  def write_log(store, attempt_id, bytes)
    writer = store.log_archive.open_writer(attempt_id, clock: -> { NOW })
    writer.append(:stdout, bytes)
    writer.close
    Hive::OutputReference.build(store.log_archive.hot_path(attempt_id), root: store.root)
  end

  def terminalize(store, running, log_reference: nil, output_references: [])
    log_reference ||= Hive::OutputReference.build(
      store.log_archive.hot_path(running.attempt_id), root: store.root
    )
    store.terminalize(
      running, outcome: "succeeded", exit_status: 0,
      final_checkpoint: { "revision" => "a" * 40 },
      output_references: output_references, log_reference: log_reference,
      now: NOW + 3
    )
  end

  def custody_lock_path(store, attempt_id)
    digest = Digest::SHA256.hexdigest(attempt_id)
    shard = digest[0, 2].to_i(16) % Hive::Attempts::LogArchive::CUSTODY_LOCK_SHARDS
    File.join(store.ephemeral_locks_root, format("log-custody-%02x.lock", shard))
  end
end
