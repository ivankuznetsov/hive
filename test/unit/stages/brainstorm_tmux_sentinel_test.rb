require "test_helper"
require "yaml"
require "hive/lock"
require "hive/stages/brainstorm_tmux"
require "hive/markers"
require "hive/task"

class BrainstormTmuxSentinelTest < Minitest::Test
  include HiveTestHelper

  FakeRunner = Struct.new(:tail) do
    def capture_pane_tail(bytes:)
      tail
    end
  end

  FakePidRunner = Struct.new(:pid) do
    def pane_pid
      pid
    end
  end

  # Pane echoes a non-terminal turn followed by a terminal turn before the
  # state file gets the terminal marker. The sentinel-fallback scan must
  # include BOTH marker names — earlier versions used `Regexp.last_match`
  # outside `scan`'s block and collapsed every entry to the final match,
  # which masked the non-terminal name.
  def test_sentinel_fallback_matches_terminal_marker_when_pane_contains_both
    with_tmp_task_folder do |task|
      File.write(task.state_file, "## Round\n<!-- WAITING -->\n")
      tail = "...assistant: <!-- WAITING -->\n...assistant: <!-- COMPLETE -->\n"
      runner = FakeRunner.new(tail)

      marker = Hive::Stages::BrainstormTmux.marker_from_sentinel_tail(task, runner)

      refute_nil marker, "should return the state file marker when pane shows the matching name"
      assert_equal :waiting, marker.name
    end
  end

  def test_sentinel_fallback_returns_nil_when_pane_only_has_other_marker
    with_tmp_task_folder do |task|
      File.write(task.state_file, "## Round\n<!-- WAITING -->\n")
      tail = "...assistant: <!-- COMPLETE -->\n"
      runner = FakeRunner.new(tail)

      assert_nil Hive::Stages::BrainstormTmux.marker_from_sentinel_tail(task, runner)
    end
  end

  def test_record_claude_pid_updates_task_lock
    with_tmp_task_folder do |task|
      Hive::Lock.acquire_task_lock(task.folder, "stage" => "2-brainstorm")

      Hive::Stages::BrainstormTmux.record_claude_pid(task, FakePidRunner.new(12_345))

      lock = YAML.safe_load(File.read(File.join(task.folder, ".lock")))
      assert_equal 12_345, lock.fetch("claude_pid")
    ensure
      Hive::Lock.release_task_lock(task.folder)
    end
  end

  private

  def with_tmp_task_folder
    with_tmp_dir do |root|
      folder = File.join(root, ".hive-state", "stages", "2-brainstorm", "slug-260514-aaaa")
      FileUtils.mkdir_p(folder)
      yield Hive::Task.new(folder)
    end
  end
end
