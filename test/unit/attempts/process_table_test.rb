require "test_helper"
require "hive/attempts/process_table"

class HiveAttemptsProcessTableTest < Minitest::Test
  include HiveTestHelper

  def test_snapshot_collects_sessions_and_groups_even_when_comm_contains_parentheses
    with_tmp_dir do |root|
      write_stat(root, "self", "1 (init) S 0 1 1 0")
      write_stat(root, "10", "10 (odd) name) S 1 20 30 0")
      write_stat(root, "11", "11 (sh) S 10 40 50 0")
      FileUtils.mkdir_p(File.join(root, "sys"))

      table = Hive::Attempts::ProcessTable.snapshot(proc_root: root)
      assert_equal Set[30, 50], table.session_ids
      assert_equal Set[20, 40], table.process_group_ids
      assert table.session_alive?(30)
      refute table.process_group_alive?(30)
    end
  end

  def test_snapshot_skips_processes_that_exit_while_listing
    with_tmp_dir do |root|
      write_stat(root, "self", "1 (init) S 0 1 1 0")
      FileUtils.mkdir_p(File.join(root, "12"))

      assert_empty Hive::Attempts::ProcessTable.snapshot(proc_root: root).session_ids
    end
  end

  def test_snapshot_is_unavailable_without_procfs_or_with_an_unparseable_entry
    with_tmp_dir do |root|
      assert_nil Hive::Attempts::ProcessTable.snapshot(proc_root: root)

      write_stat(root, "self", "1 (init) S 0 1 1 0")
      write_stat(root, "13", "garbage")
      assert_nil Hive::Attempts::ProcessTable.snapshot(proc_root: root)
    end
  end

  def test_live_host_snapshot_contains_this_process
    skip "procfs unavailable" unless File.file?("/proc/self/stat")

    table = Hive::Attempts::ProcessTable.snapshot
    assert table.session_alive?(Process.getsid)
    assert table.process_group_alive?(Process.getpgrp)
  end

  private

  def write_stat(root, entry, content)
    FileUtils.mkdir_p(File.join(root, entry))
    File.write(File.join(root, entry, "stat"), "#{content}\n")
  end
end
