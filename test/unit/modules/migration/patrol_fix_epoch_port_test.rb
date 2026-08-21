require "test_helper"
require "tmpdir"
require "hive/modules/migration/patrol_fix_epoch_port"

class PatrolFixEpochPortTest < Minitest::Test
  MODES = {
    "ordinary_patrol" => { "owner" => "legacy", "admission" => true },
    "architecture_patrol" => { "owner" => "legacy", "admission" => false }
  }.freeze

  def test_fence_guards_inventory_under_lock_and_restart_does_not_double_bump
    Dir.mktmpdir do |project|
      state_root = File.join(project, ".hive-state")
      write_state(project, state_root, epoch: 7)
      port = Hive::Modules::Migration::PatrolFixEpochPort.new(
        project_root: project, hive_state_path: state_root,
        clock: -> { Time.utc(2026, 8, 21, 4) }
      )
      events = []

      first = port.fence!(
        expected: epoch(7), ownership: MODES,
        inventory_guard: -> { events << :guard }
      )
      second = port.fence!(
        expected: epoch(7), ownership: MODES,
        inventory_guard: -> { events << :restart_guard }
      )

      assert_equal epoch(8), first
      assert_equal epoch(8), second
      assert_equal [ :guard, :restart_guard ], events
      state = Hive::Modules::Migration::Patrols.read_state(
        project, hive_state_path: state_root
      )
      assert_equal 8, state.fetch("epoch")
      assert state.fetch("admissions").values.none?

      port.activate_discovery!(expected: epoch(8), ownership: MODES)
      restored = Hive::Modules::Migration::Patrols.read_state(
        project, hive_state_path: state_root
      )
      assert_equal({ "patrol" => true, "architecture-patrol" => false },
                   restored.fetch("admissions"))
    end
  end

  def test_guard_failure_leaves_existing_epoch_and_admissions_unchanged
    Dir.mktmpdir do |project|
      state_root = File.join(project, ".hive-state")
      write_state(project, state_root, epoch: 7)
      port = Hive::Modules::Migration::PatrolFixEpochPort.new(
        project_root: project, hive_state_path: state_root
      )

      assert_raises(RuntimeError) do
        port.fence!(
          expected: epoch(7), ownership: MODES,
          inventory_guard: -> { raise "accepted at boundary" }
        )
      end

      state = Hive::Modules::Migration::Patrols.read_state(
        project, hive_state_path: state_root
      )
      assert_equal 7, state.fetch("epoch")
      assert_equal({ "patrol" => true, "architecture-patrol" => false },
                   state.fetch("admissions"))
    end
  end

  private

  def epoch(value)
    { "ordinary_patrol" => value, "architecture_patrol" => value }
  end

  def write_state(project, state_root, epoch:)
    path = Hive::Modules::Migration::Patrols.state_file(
      project, hive_state_path: state_root
    )
    FileUtils.mkdir_p(File.dirname(path))
    state = {
      "schema" => "hive-module-migration", "schema_version" => 1,
      "project" => File.basename(project), "project_root" => project,
      "epoch" => epoch, "status" => "rolled_back",
      "owners" => { "patrol" => "legacy", "architecture-patrol" => "legacy" },
      "admissions" => { "patrol" => true, "architecture-patrol" => false },
      "bindings" => {}, "blockers" => {}, "cutover_selections" => {},
      "watermarks" => {}, "shadow_started_at" => nil, "cutover_at" => nil,
      "rollback_at" => nil, "updated_at" => Time.utc(2026, 8, 21).iso8601(6)
    }
    Hive::AtomicFile.write(path, Hive::Modules::Migration::Patrols.canonical(state))
  end
end
