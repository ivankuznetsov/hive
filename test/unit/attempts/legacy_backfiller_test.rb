require "test_helper"
require "hive/attempts/legacy_backfiller"
require "hive/attempts/capacity_snapshot"

class AttemptsLegacyBackfillerTest < Minitest::Test
  include HiveTestHelper

  FakeIdentity = Struct.new(:result) do
    def status(_expected) = result
  end

  FakeLogger = Struct.new(:events) do
    def event(name, **fields) = events << [ name, fields ]
  end

  def test_trustworthy_live_legacy_lock_creates_one_compatibility_lease
    with_tmp_dir do |root|
      task_folder = File.join(root, ".hive-state", "stages", "4-execute", "demo-task")
      FileUtils.mkdir_p(task_folder)
      File.write(File.join(task_folder, "task.md"), "# task\n<!-- AGENT_WORKING -->\n")
      File.write(
        File.join(task_folder, ".lock"),
        { "pid" => 123, "process_start_time" => "start-1" }.to_yaml
      )
      store = Hive::Attempts::Store.new(root: File.join(root, "attempts"))
      project = { "name" => "demo", "path" => root,
                  "hive_state_path" => File.join(root, ".hive-state") }
      logger = FakeLogger.new([])
      backfiller = Hive::Attempts::LegacyBackfiller.new(
        store: store, process_identity: FakeIdentity.new(:matching),
        projects: -> { [ project ] }, logger: logger
      )

      first = backfiller.backfill(now: Time.utc(2026, 7, 16, 12, 0, 0))
      second = backfiller.backfill(now: Time.utc(2026, 7, 16, 12, 1, 0))

      assert_equal 1, first.length
      assert_empty second
      assert first.first.compatibility?
      assert_equal "running", first.first.state
      assert_equal 1, Hive::Attempts::CapacitySnapshot.build(store: store).global_count
      assert_equal [ :attempt_legacy_backfilled ], logger.events.map(&:first)
    end
  end

  def test_unverified_or_mismatched_lock_is_left_to_legacy_reconciliation
    %i[unverifiable mismatched].each do |identity_status|
      with_tmp_dir do |root|
        task_folder = File.join(root, ".hive-state", "stages", "4-execute", "demo-task")
        FileUtils.mkdir_p(task_folder)
        File.write(File.join(task_folder, "task.md"), "# task\n")
        File.write(File.join(task_folder, ".lock"), { "pid" => 123 }.to_yaml)
        store = Hive::Attempts::Store.new(root: File.join(root, "attempts"))
        project = { "name" => "demo", "path" => root,
                    "hive_state_path" => File.join(root, ".hive-state") }

        created = Hive::Attempts::LegacyBackfiller.new(
          store: store, process_identity: FakeIdentity.new(identity_status),
          projects: -> { [ project ] }
        ).backfill

        assert_empty created
        assert_empty store.scan.records
      end
    end
  end


  def test_malformed_and_attempt_owned_locks_are_ignored
    with_tmp_dir do |root|
      task_folder = File.join(root, ".hive-state", "stages", "4-execute", "demo-task")
      FileUtils.mkdir_p(task_folder)
      lock_path = File.join(task_folder, ".lock")
      store = Hive::Attempts::Store.new(root: File.join(root, "attempts"))
      project = { "name" => "demo", "path" => root,
                  "hive_state_path" => File.join(root, ".hive-state") }
      backfiller = Hive::Attempts::LegacyBackfiller.new(
        store: store, process_identity: FakeIdentity.new(:matching), projects: -> { [ project ] }
      )

      File.write(lock_path, "- not-a-hash\n")
      assert_empty backfiller.backfill
      File.write(lock_path, { "attempt_id" => "owned", "pid" => 1 }.to_yaml)
      assert_empty backfiller.backfill
      File.write(lock_path, "[unterminated")
      assert_empty backfiller.backfill
    end
  end

  def test_default_project_source_and_starting_revision_paths
    with_tmp_dir do |root|
      store = Hive::Attempts::Store.new(root: File.join(root, "attempts"))
      projects = [ { "name" => "demo", "path" => root } ]
      with_replaced_singleton_method(Hive::Config, :registered_projects, -> { projects }) do
        backfiller = Hive::Attempts::LegacyBackfiller.new(
          store: store, process_identity: FakeIdentity.new(:matching)
        )
        assert_equal projects, backfiller.instance_variable_get(:@projects).call

        with_tmp_git_repo do |worktree|
          task = Struct.new(:worktree_path).new(worktree)
          assert_match(/\A[0-9a-f]{40}\z/, backfiller.send(:starting_revision, task))
        end

        task = Struct.new(:worktree_path).new(root)
        assert_nil backfiller.send(:starting_revision, task)
        with_replaced_singleton_method(IO, :popen, ->(*_args, **_kwargs) { raise Errno::EACCES }) do
          assert_nil backfiller.send(:starting_revision, task)
        end
      end
    end
  end
end
