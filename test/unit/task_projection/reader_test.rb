require "test_helper"
require "hive/task_projection/reader"

class TaskProjectionReaderTest < Minitest::Test
  include HiveTestHelper

  def test_journal_replay_is_self_contained_and_does_not_publish_projection_files
    with_tmp_dir do |dir|
      write_journal(dir, [ condition_event("event-1") ])
      store = Hive::TaskProjection::Reader.new(task_folder: dir)
      projection = store.read

      assert_equal "satisfied", projection.current_condition("AgentHealthy").fetch("state")
      refute File.exist?(File.join(dir, "task-projection.json"))
      refute File.exist?(File.join(dir, "task-projection.checkpoint.json"))
    end
  end

  def test_missing_journal_projects_pristine_state_without_writing
    with_tmp_dir do |dir|
      store = Hive::TaskProjection::Reader.new(task_folder: dir)

      result = store.read_routine

      assert_equal "current", result.state
      assert result.current?
      assert_equal 0, result.journal_cursor
      assert result.projection["conditions"].fetch("current").all? do |condition|
        condition.fetch("state") == "pending"
      end
      assert_empty Dir.children(dir)
    end
  end

  def test_read_rejects_malformed_journal_and_bounded_read_reports_it
    with_tmp_dir do |dir|
      File.write(File.join(dir, Hive::TaskJournal::JOURNAL_BASENAME), "{\n")
      store = Hive::TaskProjection::Reader.new(task_folder: dir)

      assert_raises(Hive::TaskProjection::InvalidJournal) { store.read }
      bounded = store.read_bounded
      assert_equal "invalid", bounded.state
      assert_equal "journal_invalid", bounded.diagnostics.first.fetch("reason")
    end
  end

  def test_bounded_read_enforces_byte_and_event_limits_without_a_cache_fallback
    with_tmp_dir do |dir|
      write_journal(dir, [ condition_event("event-1"), condition_event("event-2") ])
      store = Hive::TaskProjection::Reader.new(task_folder: dir)

      bytes = store.read_bounded(journal_suffix_max_bytes: 1)
      events = store.read_bounded(journal_event_limit: 1)

      assert bytes.truncated
      assert events.truncated
      assert_equal "invalid", bytes.state
      assert_equal "invalid", events.state
    end
  end

  def test_routine_read_folds_history_beyond_workspace_event_and_byte_limits
    with_tmp_dir do |dir|
      events = 2_001.times.map { |index| condition_event("event-#{index}") }
      write_journal(dir, events)
      reader = Hive::TaskProjection::Reader.new(task_folder: dir)

      assert_operator File.size(reader.journal_path), :>, 1024 * 1024
      assert_equal "invalid", reader.read_bounded.state
      routine = reader.read_routine
      assert routine.current?
      assert_equal 2_001, routine.journal_records.size
    end
  end

  def test_repeated_reads_do_not_create_derived_files
    with_tmp_dir do |dir|
      write_journal(dir, [ condition_event("event-1") ])
      store = Hive::TaskProjection::Reader.new(task_folder: dir)

      assert_equal store.read.to_h, store.read.to_h
      assert_equal [ Hive::TaskJournal::JOURNAL_BASENAME ], Dir.children(dir)
    end
  end

  def test_marker_is_overlaid_without_mutating_the_journal
    with_tmp_dir do |dir|
      write_journal(dir, [ condition_event("event-1") ])
      path = File.join(dir, Hive::TaskJournal::JOURNAL_BASENAME)
      before = File.binread(path)
      marker = Hive::Markers::State.new(
        name: :execute_complete, attrs: { "mode" => "research" }, raw: nil
      )

      projection = Hive::TaskProjection::Reader.new(task_folder: dir).read(marker: marker)

      assert_equal "execute_complete", projection.to_h.dig("compatibility", "marker", "name")
      assert_equal before, File.binread(path)
    end
  end

  def test_reader_does_not_create_storage
    with_tmp_dir do |root|
      with_env("HIVE_HOME" => root, "HIVE_ATTEMPT_STORE_ROOT" => nil) do
        Hive::TaskProjection::Reader.new(task_folder: root).read
      end
      assert_empty Dir.children(root)
    end
  end

  def test_reader_rejects_symlinked_journal_and_lock
    with_tmp_dir do |dir|
      target = File.join(dir, "target")
      File.write(target, "")
      journal = File.join(dir, Hive::TaskJournal::JOURNAL_BASENAME)
      File.symlink(target, journal)
      reader = Hive::TaskProjection::Reader.new(task_folder: dir)

      assert_raises(Hive::TaskProjection::InvalidJournal) { reader.read }

      File.unlink(journal)
      File.symlink(target, File.join(dir, Hive::TaskJournal::LOCK_BASENAME))
      assert_raises(Hive::TaskProjection::InvalidJournal) { reader.read }
    end
  end

  def test_reader_rejects_a_valid_journal_bound_to_another_task
    with_tmp_dir do |dir|
      write_journal(dir, [ condition_event("event-1") ])
      workflow = Struct.new(:id).new(:coding)
      task = Struct.new(:slug, :id, :workflow).new("other-task", "99", workflow)
      reader = Hive::TaskProjection::Reader.new(task_folder: dir, task: task)

      error = assert_raises(Hive::TaskProjection::InvalidJournal) { reader.read }
      assert_includes error.message, "different task"
    end
  end

  def test_reader_rejects_attempt_identity_changes_inside_one_journal
    with_tmp_dir do |dir|
      changed = condition_event("event-2").merge("ownership_generation" => "other-owner")
      write_journal(dir, [ condition_event("event-1"), changed ])

      error = assert_raises(Hive::TaskProjection::InvalidJournal) do
        Hive::TaskProjection::Reader.new(task_folder: dir).read
      end
      assert_includes error.message, "changes identity"
    end
  end

  def test_first_append_lock_appearance_forces_a_locked_retry
    with_tmp_dir do |dir|
      lock_path = File.join(dir, Hive::TaskJournal::LOCK_BASENAME)
      journal_path = File.join(dir, Hive::TaskJournal::JOURNAL_BASENAME)
      writer_lock = nil
      reader_class = Class.new(Hive::TaskProjection::Reader) do
        define_method(:initialize) do |on_missing_lock:, **options|
          @on_missing_lock = on_missing_lock
          @missing_lock_observed = false
          super(**options)
        end

        private

        define_method(:open_regular) do |path, label, missing:|
          file = super(path, label, missing: missing)
          if path == lock_path && file.nil? && !@missing_lock_observed
            @missing_lock_observed = true
            @on_missing_lock.call
          end
          file
        end
      end
      reader = reader_class.new(
        task_folder: dir,
        on_missing_lock: lambda do
          writer_lock = File.open(lock_path, File::RDWR | File::CREAT, 0o644)
          writer_lock.flock(File::LOCK_EX)
          File.binwrite(journal_path, "{partial")
        end
      )

      result = reader.read_bounded

      assert_equal "partial", result.state
      assert_equal "journal_lock_busy", result.diagnostics.first.fetch("reason")
    ensure
      writer_lock&.flock(File::LOCK_UN)
      writer_lock&.close
    end
  end

  def test_bounded_read_reports_a_busy_writer_without_waiting_or_calling_it_corrupt
    with_tmp_dir do |dir|
      lock_path = File.join(dir, Hive::TaskJournal::LOCK_BASENAME)
      File.write(lock_path, "")
      lock = File.open(lock_path, File::RDWR)
      lock.flock(File::LOCK_EX)
      reader = Hive::TaskProjection::Reader.new(task_folder: dir)
      result = nil
      read = Thread.new { result = reader.read_bounded }

      assert read.join(1), "bounded task-history read blocked behind a writer"
      assert_equal "partial", result.state
      refute result.current?
      assert_equal "journal_lock_busy", result.diagnostics.first.fetch("reason")
    ensure
      lock&.flock(File::LOCK_UN)
      lock&.close
      read&.join(1)
      read&.kill
    end
  end

  def test_reader_releases_shared_lock_before_folding_snapshot
    with_tmp_dir do |dir|
      write_journal(dir, [ condition_event("event-1") ])
      lock_path = File.join(dir, Hive::TaskJournal::LOCK_BASENAME)
      File.write(lock_path, "")
      projector = Object.new
      projector.define_singleton_method(:project) do |**attributes|
        File.open(lock_path, File::RDWR) do |lock|
          raise "journal lock retained during projection" unless
            lock.flock(File::LOCK_EX | File::LOCK_NB)
        end
        Hive::TaskProjection.project(**attributes)
      end

      projection = Hive::TaskProjection::Reader.new(
        task_folder: dir, projector: projector
      ).read

      assert_equal "satisfied", projection.current_condition("AgentHealthy").fetch("state")
    end
  end

  private

  def write_journal(dir, records)
    body = records.map { |record| JSON.generate(record) }.join("\n")
    File.write(File.join(dir, Hive::TaskJournal::JOURNAL_BASENAME), "#{body}\n")
  end

  def condition_event(event_id)
    {
      "schema" => Hive::TaskJournal::Envelope::SCHEMA,
      "schema_version" => Hive::TaskJournal::Envelope::SCHEMA_VERSION,
      "event_id" => event_id,
      "event_type" => "condition_observed",
      "occurred_at" => "2026-07-17T12:00:00.000000Z",
      "observed_at" => "2026-07-17T12:00:00.000000Z",
      "task" => { "id" => "42", "slug" => "task" },
      "workflow" => "coding",
      "stage" => "4-execute",
      "attempt_id" => "attempt-1",
      "task_generation" => 1,
      "ownership_generation" => "owner-1",
      "commit_generation" => 0,
      "reason" => "lease_observed",
      "evidence" => [ {
        "type" => "attempt_lease", "attempt_id" => "attempt-1",
        "lease_version" => 1, "state" => "running"
      } ],
      "provenance" => { "source" => "test" },
      "payload" => { "condition" => "AgentHealthy", "state" => "satisfied" }
    }
  end
end
