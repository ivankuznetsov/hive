require "test_helper"
require "hive/runtime_control_plane"
require "hive/daemon/operational_snapshot"

class RuntimeOperationalRepositoryTest < Minitest::Test
  include HiveTestHelper

  DAEMON = { "pid" => 42 }.freeze

  def test_snapshot_encoding_precedes_sql_and_projection_stays_bound
    with_tmp_dir do |root|
      database = Hive::RuntimeControlPlane::Database.new(path: File.join(root, "runtime.sqlite3"))
      database.migrate!
      repository = Hive::RuntimeControlPlane::OperationalRepository.new(database: database)
      snapshot = { "phase" => "complete", "tick_sequence" => 7, "daemon" => { "pid" => 42 } }
      projection = { "tick_sequence" => 7, "daemon" => { "pid" => 42 } }
      acquired = false
      original_transaction = database.method(:transaction)
      database.define_singleton_method(:transaction) do |**options, &block|
        original_transaction.call(**options) do |db|
          acquired = true
          block.call(db)
        ensure
          acquired = false
        end
      end
      codec = Hive::RuntimeControlPlane::Codec
      original_encoder = codec.method(:dump_json)
      testcase = self
      encoder = lambda do |document|
        testcase.refute acquired, "snapshot preparation must precede lock acquisition" if document.key?("snapshot")
        original_encoder.call(document)
      end
      with_replaced_singleton_method(codec, :dump_json, encoder) do
        repository.publish(snapshot, status_projection: projection)
      end
      assert_equal snapshot, repository.snapshot
      assert_equal projection, repository.status_projection
      assert_raises(Hive::RuntimeControlPlane::IntegrityError) do
        repository.publish(snapshot, status_projection: projection.merge("tick_sequence" => 8))
      end
      assert_equal projection, repository.status_projection
    ensure
      database&.disconnect
    end
  end

  # The real payload is ~5 MB and only `generated_at`/`age_seconds` move on
  # an idle tick. Neither may rewrite the payload file or bloat the row.
  def test_unchanged_payload_is_not_rewritten_and_the_row_stays_small
    with_repository do |database, repository, root|
      payload = status_payload(generated_at: "2026-11-14T10:00:00.000000Z", age_offset: 0)
      payload_bytes = Hive::RuntimeControlPlane::Codec.dump_json(payload).bytesize
      writes = []
      in_transaction = []
      original_write = Hive::AtomicFile.method(:write)
      payload_root = Hive::Paths.operational_status_payload_root(root)
      recorder = lambda do |path, content, **options|
        if path.start_with?("#{payload_root}/")
          writes << path
          in_transaction << (database.instance_variable_get(:@connection)&.in_transaction? == true)
        end
        original_write.call(path, content, **options)
      end

      with_replaced_singleton_method(Hive::AtomicFile, :write, recorder) do
        publish_tick(repository, 1, payload)
        changed_clock = status_payload(generated_at: "2026-11-14T10:00:30.000000Z", age_offset: 30)
        publish_tick(repository, 2, changed_clock)
        assert_equal changed_clock, repository.status_projection.fetch("payload")
      end

      assert_equal 1, writes.size, "an unchanged payload must not be rewritten"
      assert_equal [ false ], in_transaction, "the payload file is written before the write lock"
      assert_equal 1, payload_files(root).size
      row_bytes = database.read { |db| db[:daemon_runtime].get(:observation_json).bytesize }
      assert_operator row_bytes, :<, payload_bytes / 10,
                      "the daemon_runtime row must not carry the payload body"
      projection = repository.status_projection
      assert_equal 2, projection.fetch("tick_sequence")
      assert_equal "2026-11-14T10:00:30.000000Z", projection.dig("payload", "generated_at")
      assert_equal [ 30, 31 ], projection.dig("payload", "projects", 0, "tasks").map { |task| task.fetch("age_seconds") }
      assert_equal projection.dig("payload", "projects", 0, "tasks", 0).keys.sort,
                   projection.dig("payload", "projects", 0, "tasks", 0).keys
    end
  end

  def test_material_change_writes_a_new_payload_and_prunes_old_files
    with_repository do |_database, repository, root|
      payloads = (1..5).map do |tick|
        status_payload(generated_at: "2026-11-14T10:00:0#{tick}.000000Z", age_offset: tick,
                       detail: "revision #{tick}")
      end
      payloads.each_with_index { |payload, index| publish_tick(repository, index + 1, payload) }

      assert_equal payloads.last, repository.status_projection.fetch("payload")
      assert_equal Hive::RuntimeControlPlane::OperationalRepository::RETAINED_PAYLOADS,
                   payload_files(root).size
    end
  end

  def test_readers_fail_closed_when_the_payload_file_is_missing_or_substituted
    with_repository do |_database, repository, root|
      payload = status_payload(generated_at: "2026-11-14T10:00:00.000000Z", age_offset: 0)
      publish_tick(repository, 1, payload)
      path = payload_files(root).fetch(0)
      original = File.binread(path)

      substituted = original.sub("plan review", "plan rev1ew")
      assert_equal original.bytesize, substituted.bytesize
      File.binwrite(path, substituted)
      error = assert_raises(Hive::RuntimeControlPlane::IntegrityError) { repository.status_projection }
      assert_equal :projection_payload_mismatch, error.code

      File.binwrite(path, original + " ")
      error = assert_raises(Hive::RuntimeControlPlane::IntegrityError) { repository.status_projection }
      assert_equal :projection_payload_mismatch, error.code

      File.unlink(path)
      error = assert_raises(Hive::RuntimeControlPlane::IntegrityError) { repository.status_projection }
      assert_equal :projection_payload_unavailable, error.code
      assert_equal "complete", repository.snapshot.fetch("phase"), "the scheduler snapshot stays readable"

      # A later publish of the same content repairs the externally removed file.
      publish_tick(repository, 2, payload)
      assert_equal payload, repository.status_projection.fetch("payload")
    end
  end

  def test_a_mismatched_source_binding_still_fails_closed_with_an_external_payload
    with_repository do |database, repository, _root|
      payload = status_payload(generated_at: "2026-11-14T10:00:00.000000Z", age_offset: 0)
      publish_tick(repository, 1, payload)
      now = Time.utc(2026, 11, 14, 10)
      snapshot = {
        "status" => "current", "tick_sequence" => 1, "daemon" => DAEMON,
        "observed_at" => now.iso8601(6), "valid_until" => (now + 90).iso8601(6)
      }
      reader = Hive::Daemon::OperationalSnapshot::StatusCache::Reader.new(repository: repository)
      assert_equal payload, reader.read(snapshot: snapshot, now: now).fetch("payload"),
                   "a source-bound projection reaches status readers with its full payload"

      rewrite_document(database) { |document| document.fetch("status_projection")["tick_sequence"] = 2 }

      error = assert_raises(Hive::RuntimeControlPlane::IntegrityError) { repository.status_projection }
      assert_equal :projection_source_mismatch, error.code
      assert_nil reader.read(snapshot: snapshot.merge("tick_sequence" => 2), now: now)
    end
  end

  def test_a_malformed_payload_reference_fails_closed
    corruptions = {
      "task age outside the payload" => ->(projection) { projection.dig("payload_reference", "task_age_seconds") << [ 0, 9, 1 ] },
      "negative task age position" => ->(projection) { projection.dig("payload_reference", "task_age_seconds")[0] = [ -1, 0, 1 ] },
      "task ages not a list" => ->(projection) { projection.fetch("payload_reference")["task_age_seconds"] = {} },
      "reference not an object" => ->(projection) { projection["payload_reference"] = "sha256" },
      "inline payload beside a reference" => ->(projection) { projection["payload"] = {} }
    }
    corruptions.each do |label, corrupt|
      with_repository do |database, repository, _root|
        publish_tick(repository, 1, status_payload(generated_at: "2026-11-14T10:00:00.000000Z", age_offset: 0))
        rewrite_document(database) { |document| corrupt.call(document.fetch("status_projection")) }

        error = assert_raises(Hive::RuntimeControlPlane::IntegrityError, label) { repository.status_projection }
        assert_equal :projection_payload_invalid, error.code, label
      end
    end
  end

  def test_rows_with_an_inline_payload_remain_readable
    with_repository do |database, repository, _root|
      payload = status_payload(generated_at: "2026-11-14T10:00:00.000000Z", age_offset: 0)
      publish_tick(repository, 1, payload)
      rewrite_document(database) do |document|
        document.fetch("status_projection").delete("payload_reference")
        document.fetch("status_projection")["payload"] = payload
      end

      assert_equal payload, repository.status_projection.fetch("payload")
    end
  end

  def test_unwritable_payload_storage_publishes_the_snapshot_without_a_projection
    with_tmp_dir do |root|
      database = Hive::RuntimeControlPlane::Database.new(path: File.join(root, "runtime.sqlite3"))
      database.migrate!
      File.write(Hive::Paths.operational_status_payload_root(root), "not a directory")
      repository = Hive::RuntimeControlPlane::OperationalRepository.new(database: database)

      _out, err = capture_io do
        publish_tick(repository, 1, status_payload(generated_at: "2026-11-14T10:00:00.000000Z", age_offset: 0))
      end

      assert_includes err, "operational_projection_unavailable"
      assert_equal 1, repository.snapshot.fetch("tick_sequence")
      assert_nil repository.status_projection

      # Reporting must never turn a degraded projection into a failed tick.
      broken_stderr = Object.new
      broken_stderr.define_singleton_method(:write) { |*| raise IOError, "stderr closed" }
      original_stderr = $stderr
      begin
        $stderr = broken_stderr
        publish_tick(repository, 2, status_payload(generated_at: "2026-11-14T10:00:30.000000Z", age_offset: 30))
      ensure
        $stderr = original_stderr
      end
      assert_equal 2, repository.snapshot.fetch("tick_sequence")
    ensure
      database&.disconnect
    end
  end

  private

  def with_repository
    with_tmp_dir do |root|
      database = Hive::RuntimeControlPlane::Database.new(path: File.join(root, "runtime.sqlite3"))
      database.migrate!
      yield database, Hive::RuntimeControlPlane::OperationalRepository.new(database: database), root
    ensure
      database&.disconnect
    end
  end

  def publish_tick(repository, tick, payload)
    snapshot = { "phase" => "complete", "tick_sequence" => tick, "daemon" => DAEMON }
    repository.publish(snapshot, status_projection: {
      "schema" => Hive::Daemon::OperationalSnapshot::StatusCache::SCHEMA,
      "schema_version" => Hive::Daemon::OperationalSnapshot::StatusCache::SCHEMA_VERSION,
      "daemon" => DAEMON, "tick_sequence" => tick,
      "published_at" => payload.fetch("generated_at"),
      "valid_until" => payload.fetch("generated_at"),
      "payload" => payload
    })
  end

  def status_payload(generated_at:, age_offset:, detail: "unchanged")
    {
      "schema" => "hive-status", "schema_version" => 9, "ok" => true,
      "generated_at" => generated_at,
      "projects" => [
        {
          "name" => "demo",
          "tasks" => [
            { "slug" => "alpha", "age_seconds" => age_offset, "plan_review" => { "notes" => "plan review #{'x' * 65_536}" },
              "detail" => detail },
            { "slug" => "beta", "age_seconds" => age_offset + 1, "plan_review" => nil }
          ]
        },
        { "name" => "empty", "tasks" => [] }
      ]
    }
  end

  def payload_files(root)
    Dir.glob(File.join(Hive::Paths.operational_status_payload_root(root), "*.json")).sort
  end

  def rewrite_document(database)
    codec = Hive::RuntimeControlPlane::Codec
    database.transaction(operation: "test.rewrite_operational_document") do |db|
      dataset = db[:daemon_runtime]
      document = codec.load_json(dataset.get(:observation_json))
      yield document
      dataset.update(observation_json: codec.dump_json(document))
    end
  end
end
