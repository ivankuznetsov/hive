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

  FakeInteractiveRunner = Struct.new(:name, :tails, :sent_keys) do
    def capture_pane_tail(bytes:)
      tails.shift || tails.last || ""
    end

    def send_keys(*keys)
      sent_keys.concat(keys)
      true
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

  def test_prepare_claude_session_confirms_trust_prompt_before_ready
    runner = FakeInteractiveRunner.new(
      "hive-2-brainstorm-test",
      [
        "Quick safety check\n❯ 1. Yes, I trust this folder\nEnter to confirm",
        "Claude Code v2.1.128\n❯ Try \"refactor <filepath>\""
      ],
      []
    )

    assert Hive::Stages::BrainstormTmux.prepare_claude_session!(runner)
    assert_equal [ "Enter" ], runner.sent_keys
  end

  def test_prepare_claude_session_trust_prompt_branch_respects_deadline
    runner = FakeInteractiveRunner.new(
      "hive-2-brainstorm-test",
      [
        "Quick safety check\n❯ 1. Yes, I trust this folder\nEnter to confirm",
        "Quick safety check\n❯ 1. Yes, I trust this folder\nEnter to confirm"
      ],
      []
    )
    original = Hive::Stages::BrainstormTmux.singleton_class.instance_method(:claude_ready_wait_timeout)
    Hive::Stages::BrainstormTmux.define_singleton_method(:claude_ready_wait_timeout) { 0.01 }

    err = assert_raises(Hive::AgentError) do
      Hive::Stages::BrainstormTmux.prepare_claude_session!(runner)
    end
    assert_match(/did not become ready/, err.message)
    refute_empty runner.sent_keys, "should have sent at least one Enter before timing out"
  ensure
    Hive::Stages::BrainstormTmux.singleton_class.send(:define_method, :claude_ready_wait_timeout, original) if original
  end

  def test_prepare_claude_session_does_not_treat_permission_prompt_as_ready
    runner = FakeInteractiveRunner.new(
      "hive-2-brainstorm-test",
      [
        "Claude Code v2.1.128\nDo you want to make this edit to brainstorm.md?\n❯ 1. Yes",
        "Claude Code v2.1.128\nDo you want to make this edit to brainstorm.md?\n❯ 1. Yes"
      ],
      []
    )
    original = Hive::Stages::BrainstormTmux.singleton_class.instance_method(:claude_ready_wait_timeout)
    Hive::Stages::BrainstormTmux.define_singleton_method(:claude_ready_wait_timeout) { 0.01 }

    err = assert_raises(Hive::AgentError) do
      Hive::Stages::BrainstormTmux.prepare_claude_session!(runner)
    end
    assert_match(/did not become ready/, err.message)
  ensure
    Hive::Stages::BrainstormTmux.singleton_class.send(:define_method, :claude_ready_wait_timeout, original) if original
  end

  def test_orphan_sweep_passes_double_dash_before_add_dir_pattern
    with_tmp_task_folder do |task|
      calls = []
      status_ok = fake_status(success: true, exitstatus: 0)
      original = Open3.singleton_class.instance_method(:capture3)
      Open3.define_singleton_method(:capture3) do |*args|
        calls << args
        case args.first
        when "pgrep"
          [ "123 claude --add-dir #{task.folder}\n", "", status_ok ]
        when "pkill"
          [ "", "", status_ok ]
        else
          raise "unexpected command: #{args.inspect}"
        end
      end

      Hive::Stages::BrainstormTmux.sweep_orphan_processes(task)

      assert_equal "pgrep", calls.fetch(0).fetch(0)
      assert_equal "--", calls.fetch(0).fetch(2)
      assert_match(/\A--add-dir\[.+\]/, calls.fetch(0).fetch(3))
      refute_includes calls.fetch(0).fetch(3), "(?:"
      assert_equal "pkill", calls.fetch(1).fetch(0)
      assert_equal "--", calls.fetch(1).fetch(2)
      assert_equal calls.fetch(0).fetch(3), calls.fetch(1).fetch(3)
    ensure
      Open3.singleton_class.send(:define_method, :capture3, original) if original
    end
  end

  def test_orphan_sweep_pattern_is_valid_pgrep_regex
    skip "pgrep is not installed" unless system("pgrep", "-V", out: File::NULL, err: File::NULL)

    with_tmp_task_folder do |task|
      pattern = Hive::Stages::BrainstormTmux.orphan_sweep_pattern(task)

      _out, err, status = Open3.capture3("pgrep", "-f", "--", pattern)

      assert_includes [ 0, 1 ], status.exitstatus, err
    end
  end

  def test_wrapper_command_uses_bypass_permissions_with_limited_tools
    with_tmp_task_folder do |task|
      profile = Struct.new(:bin).new("/bin/claude")

      command = Hive::Stages::BrainstormTmux.wrapper_command(task, profile)

      mode_index = command.index("--permission-mode")
      refute_nil mode_index
      assert_equal "bypassPermissions", command.fetch(mode_index + 1)
      tools_index = command.index("--allowedTools")
      refute_nil tools_index
      assert_equal "Read,Write,Edit,LS", command.fetch(tools_index + 1)
    end
  end

  private

  def fake_status(success:, exitstatus:)
    Struct.new(:success_value, :exitstatus) do
      def success?
        success_value
      end
    end.new(success, exitstatus)
  end

  def with_tmp_task_folder
    with_tmp_dir do |root|
      folder = File.join(root, ".hive-state", "stages", "2-brainstorm", "slug-260514-aaaa")
      FileUtils.mkdir_p(folder)
      yield Hive::Task.new(folder)
    end
  end
end
