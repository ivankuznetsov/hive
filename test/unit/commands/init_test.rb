require "test_helper"
require "hive/commands/init"
require "fileutils"
require "stringio"

class HiveCommandsInitTest < Minitest::Test
  include HiveTestHelper

  def command(project_path = "/tmp/project")
    Hive::Commands::Init.new(project_path)
  end

  def status(success)
    result = Object.new
    result.define_singleton_method(:success?) { success }
    result
  end

  def default_init_limits(config_key)
    Hive::Commands::Init::Prompts::LIMIT_KEYS.each_with_object({}) do |key, limits|
      limits[key] = Hive::Config::DEFAULTS.fetch(config_key).fetch(key)
    end
  end

  def project_config_answers
    input = StringIO.new
    input.define_singleton_method(:tty?) { false }
    Hive::Commands::Init::Prompts.new(input: input, output: StringIO.new, summary_io: StringIO.new).collect
  end

  def project_config_binding(answers = project_config_answers)
    Hive::Commands::Init::ProjectConfigBinding.new(
      project_name: "example",
      default_branch: "main",
      worktree_root: "/tmp/example.worktrees",
      answers: answers
    )
  end

  def test_project_config_binding_accepts_complete_prompt_answers
    answers = project_config_answers.merge(
      "claude_mode" => "headless",
      "patrol_mode" => "high",
      "triage_bias" => "safetyist",
      "daemon_enabled" => false
    )

    config_binding = project_config_binding(answers)

    assert_equal "example", config_binding.project_name
    assert_equal "main", config_binding.default_branch
    assert_equal "/tmp/example.worktrees", config_binding.worktree_root
    assert_equal "claude", config_binding.planning_agent
    assert_equal "headless", config_binding.claude_mode
    assert_equal "codex", config_binding.development_agent
    assert_equal Hive::Commands::Init::Prompts::DEFAULT_REVIEWER_NAMES, config_binding.enabled_reviewers
    assert_equal Hive::Commands::Init::Prompts::DEFAULT_PATROL_REVIEWER_NAMES, config_binding.patrol_reviewers
    assert_equal "high", config_binding.patrol_mode
    assert_equal "safetyist", config_binding.triage_bias
    assert_equal default_init_limits("budget_usd"), config_binding.budgets
    assert_equal default_init_limits("timeout_sec"), config_binding.timeouts
    refute config_binding.daemon_enabled
  end

  def test_project_config_binding_requires_every_prompt_answer_key
    project_config_answers.keys.each do |key|
      answers = project_config_answers
      answers.delete(key)

      error = assert_raises(KeyError) do
        project_config_binding(answers)
      end
      assert_includes error.message, key
    end
  end

  def test_project_config_binding_requires_every_limit_answer_key
    %w[budgets timeouts].each do |section|
      Hive::Commands::Init::Prompts::LIMIT_KEYS.each do |key|
        answers = project_config_answers
        answers[section] = answers.fetch(section).dup
        answers.fetch(section).delete(key)

        error = assert_raises(KeyError) do
          project_config_binding(answers)
        end
        assert_includes error.message, key
      end
    end
  end

  def test_project_config_binding_requires_limit_sections_to_be_fetchable
    %w[budgets timeouts].each do |section|
      answers = project_config_answers
      answers[section] = nil

      error = assert_raises(KeyError) do
        project_config_binding(answers)
      end
      assert_includes error.message, section
    end
  end

  def test_run_init_preflight_warns_when_doctor_reports_config_error
    cmd = command
    warnings = []
    fake_doctor = Object.new
    fake_doctor.define_singleton_method(:call) { Hive::Commands::Doctor::EXIT_CONFIG_ERROR }
    original_load = Hive::Config.singleton_class.instance_method(:load)
    original_doctor_new = Hive::Commands::Doctor.singleton_class.instance_method(:new)
    Hive::Config.define_singleton_method(:load) { |_path| {} }
    Hive::Commands::Doctor.define_singleton_method(:new) { |**_kwargs| fake_doctor }
    cmd.define_singleton_method(:write_warn) { |line| warnings << line }

    cmd.send(:run_init_preflight!)

    assert_equal [ "hive: doctor pre-flight — config issue detected; run `hive doctor` for details" ], warnings
  ensure
    Hive::Config.singleton_class.define_method(:load, original_load) if original_load
    Hive::Commands::Doctor.singleton_class.define_method(:new, original_doctor_new) if original_doctor_new
  end

  def test_write_warn_swallows_epipe
    cmd = command
    cmd.define_singleton_method(:warn) { |_line| raise Errno::EPIPE, "closed pipe" }

    assert_nil cmd.send(:write_warn, "hive: warning")
  end

  def test_register_daemon_service_warns_when_installer_reports_failure
    cmd = command
    warnings = []
    fake_installer = Object.new
    # Tolerate the installer contract (install!(autostart:, force:)), not
    # just init's current call site, so a future force: arg can't make
    # this read as an unrelated ArgumentError.
    fake_installer.define_singleton_method(:install!) { |autostart:, **| autostart ? :failed : :ok }
    fake_installer.define_singleton_method(:messages) { [ "created service" ] }
    original_new = Hive::Commands::Daemon::ServiceInstaller.singleton_class.instance_method(:new)
    Hive::Commands::Daemon::ServiceInstaller.define_singleton_method(:new) do |binary_path:|
      raise "unexpected binary path" unless binary_path == "/tmp/hive"

      fake_installer
    end
    cmd.define_singleton_method(:record_daemon_autostart!) { |_autostart| nil }
    cmd.define_singleton_method(:current_binary_path) { "/tmp/hive" }
    cmd.define_singleton_method(:write_warn) { |line| warnings << line }

    cmd.send(:register_daemon_service!, autostart: true)

    assert_includes warnings, "hive: created service"
    assert_includes warnings, "hive: daemon service registration reported a failure; run `hive doctor` and check daemon logs"
  ensure
    Hive::Commands::Daemon::ServiceInstaller.singleton_class.define_method(:new, original_new) if original_new
  end

  def test_register_daemon_service_records_autostart_even_when_unavailable
    # The PR's load-bearing semantic: autostart intent is persisted even
    # when the host cannot actually enable the service. record_daemon_autostart!
    # is NOT stubbed here, so the real global config is written.
    with_tmp_global_config do |home|
      cmd = command
      fake_installer = Object.new
      fake_installer.define_singleton_method(:install!) { |autostart:, **| :autostart_unavailable }
      fake_installer.define_singleton_method(:messages) do
        [ "systemd not detected; daemon unit was written but autostart was not enabled." ]
      end
      original_new = Hive::Commands::Daemon::ServiceInstaller.singleton_class.instance_method(:new)
      Hive::Commands::Daemon::ServiceInstaller.define_singleton_method(:new) { |binary_path:| fake_installer }
      cmd.define_singleton_method(:current_binary_path) { "/tmp/hive" }
      cmd.define_singleton_method(:write_warn) { |_line| nil }

      cmd.send(:register_daemon_service!, autostart: true)

      global = YAML.safe_load(File.read(File.join(home, "config.yml")))
      assert_equal true, global.dig("daemon", "autostart"),
                   "autostart intent is recorded even when the host cannot enable the service"
    ensure
      Hive::Commands::Daemon::ServiceInstaller.singleton_class.define_method(:new, original_new) if original_new
    end
  end

  def test_register_daemon_service_warns_on_permission_failures_and_hive_errors
    cmd = command
    warnings = []
    cmd.define_singleton_method(:record_daemon_autostart!) { |_autostart| nil }
    cmd.define_singleton_method(:write_warn) { |line| warnings << line }

    cmd.define_singleton_method(:current_binary_path) { raise Errno::EACCES, "denied" }
    cmd.send(:register_daemon_service!, autostart: false)

    cmd.define_singleton_method(:current_binary_path) { raise Hive::Error, "bad service" }
    cmd.send(:register_daemon_service!, autostart: false)

    assert(warnings.any? { |line| line.include?("fix permissions and re-run `hive init`") })
    assert_includes warnings, "hive: daemon service registration failed: bad service"
  end

def test_register_daemon_service_degrades_unexpected_error_to_warning_with_bug_hint
  # An unexpected StandardError (not Errno/Hive::Error) must not abort an
  # already-committed init; it degrades to a warning with a bug-report hint.
  cmd = command
  warnings = []
  cmd.define_singleton_method(:record_daemon_autostart!) { |_autostart| nil }
  cmd.define_singleton_method(:write_warn) { |line| warnings << line }
  cmd.define_singleton_method(:current_binary_path) { raise "kaboom" }

  cmd.send(:register_daemon_service!, autostart: true)

  assert(warnings.any? { |line| line.include?("RuntimeError: kaboom") && line.include?("this may be a hive bug") },
         "unexpected errors must be reported as a possible hive bug, not swallowed or re-raised")
end

def test_rollback_config_file_removes_file_and_records_result
  Dir.mktmpdir("hive-init-unit") do |dir|
    state = File.join(dir, ".hive-state")
    FileUtils.mkdir_p(state)
    config = File.join(state, "config.yml")
    File.write(config, "project_name: demo\n")
    ops = Struct.new(:hive_state_path).new(state)
    results = []
    errors = []

    command.send(:rollback_config_file, ops, results, errors)

    refute File.exist?(config)
    assert_equal [ "config.yml" ], results
    assert_empty errors
  end
end

def test_rollback_config_file_records_cleanup_errors
  Dir.mktmpdir("hive-init-unit") do |dir|
    state = File.join(dir, ".hive-state")
    FileUtils.mkdir_p(state)
    config = File.join(state, "config.yml")
    File.write(config, "project_name: demo\n")
    ops = Struct.new(:hive_state_path).new(state)
    results = []
    errors = []
    original = FileUtils.singleton_class.instance_method(:rm_f)
    FileUtils.define_singleton_method(:rm_f) { |_path| raise Errno::EACCES, "denied" }

    command.send(:rollback_config_file, ops, results, errors)

    assert_empty results
    assert_match(/config.yml cleanup failed: Errno::EACCES/, errors.first)
  ensure
    FileUtils.singleton_class.define_method(:rm_f, original) if original
  end
end

def test_rollback_git_helpers_record_command_failures
  Dir.mktmpdir("hive-init-unit") do |dir|
    state = File.join(dir, ".hive-state")
    FileUtils.mkdir_p(state)
    ops = Struct.new(:hive_state_path) do
      def hive_state_branch_exists? = true
    end.new(state)
    original = Open3.singleton_class.instance_method(:capture3)
    failure = status(false)
    Open3.define_singleton_method(:capture3) { |*_args| [ "", "git said no\nmore", failure ] }
    results = []
    errors = []

    command.send(:rollback_hive_state_worktree, ops, results, errors)
    command.send(:rollback_hive_state_branch, ops, results, errors)

    assert_empty results
    assert_equal 2, errors.size
    assert(errors.all? { |error| error.include?("git said no") })
  ensure
    Open3.singleton_class.define_method(:capture3, original) if original
  end
end

def test_report_partial_init_rollback_warns_with_recovery_command
  ops = Struct.new(:hive_state_path).new("/tmp/demo/.hive-state")
  warnings = []
  cmd = command("/tmp/demo")
  cmd.define_singleton_method(:write_warn) { |line| warnings << line }

  cmd.send(:report_partial_init_rollback, ops, [ "config.yml" ], [ "git failed" ])

  assert_match(/rollback incomplete: git failed/, warnings.first)
  assert_match(%r{git -C /tmp/demo worktree remove /tmp/demo/.hive-state --force}, warnings.last)
  assert_match(/git -C \/tmp\/demo branch -D hive\/state/, warnings.last)
end

def test_rollback_error_prefers_stderr_then_stdout_and_handles_blank_detail
  cmd = command

  assert_equal "cmd failed: err", cmd.send(:rollback_error, "cmd", "out\nmore", "err\nmore")
  assert_equal "cmd failed: out", cmd.send(:rollback_error, "cmd", "out\nmore", "")
  assert_equal "cmd failed", cmd.send(:rollback_error, "cmd", "", "")
end

def test_snapshot_path_captures_symlinks_directories_and_absent_paths
  Dir.mktmpdir("hive-init-unit") do |dir|
    target = File.join(dir, "target.txt")
    symlink = File.join(dir, "link")
    directory = File.join(dir, "directory")
    File.write(target, "target\n")
    File.symlink("target.txt", symlink)
    FileUtils.mkdir_p(directory)
    FileUtils.chmod(0o750, directory)
    cmd = command(dir)

    assert_equal({ type: :symlink, target: "target.txt", mode: 0o777 },
                 cmd.send(:snapshot_path, symlink))
    assert_equal({ type: :directory, mode: 0o750 },
                 cmd.send(:snapshot_path, directory))
    assert_equal({ type: :absent },
                 cmd.send(:snapshot_path, File.join(dir, "missing")))
  end
end

def test_rollback_main_checkout_commits_records_reset_failures
  cmd = command("/tmp/demo")
  cmd.define_singleton_method(:current_project_head) { "new-head" }
  original = Open3.singleton_class.instance_method(:capture3)
  failure = status(false)
  Open3.define_singleton_method(:capture3) { |*_args| [ "", "reset denied\n", failure ] }
  results = []
  errors = []

  cmd.send(:rollback_main_checkout_commits, { head: "old-head" }, results, errors)

  assert_empty results
  assert_equal [ "git reset --soft failed: reset denied" ], errors
ensure
  Open3.singleton_class.define_method(:capture3, original) if original
end

def test_restore_init_side_effect_paths_records_individual_restore_errors
  cmd = command
  cmd.define_singleton_method(:restore_init_side_effect_path) do |_path, _snapshot|
    raise Errno::EACCES, "blocked"
  end
  errors = []

  cmd.send(:restore_init_side_effect_paths, { "/tmp/demo" => { type: :absent } }, [], errors)

  assert_match(%r{/tmp/demo restore failed: Errno::EACCES}, errors.first)
end

def test_restore_init_side_effect_path_restores_symlink_and_directory_snapshots
  Dir.mktmpdir("hive-init-unit") do |dir|
    cmd = command(dir)
    symlink = File.join(dir, "nested", "link")
    directory = File.join(dir, "restored-dir")

    assert cmd.send(:restore_init_side_effect_path, symlink, { type: :symlink, target: "../target" })
    assert File.symlink?(symlink)
    assert_equal "../target", File.readlink(symlink)

    File.write(directory, "file in the way\n")
    assert cmd.send(:restore_init_side_effect_path, directory, { type: :directory, mode: 0o700 })
    assert File.directory?(directory)
    assert_equal 0o700, File.stat(directory).mode & 0o777

    refute cmd.send(:restore_init_side_effect_path, File.join(dir, "noop"), { type: :unknown })
  end
end

def test_rollback_partial_init_reports_rollback_exceptions
  ops = Struct.new(:hive_state_path).new("/tmp/demo/.hive-state")
  warnings = []
  cmd = command("/tmp/demo")
  cmd.define_singleton_method(:rollback_config_file) { |_ops, _results, _errors| raise "rollback boom" }
  cmd.define_singleton_method(:write_warn) { |line| warnings << line }

  cmd.send(:rollback_partial_init, ops)

  assert_equal "hive: partial init failed; rollback failed: RuntimeError: rollback boom", warnings.first
  assert_match(%r{git -C /tmp/demo worktree remove /tmp/demo/.hive-state --force}, warnings.last)
end

def test_emit_json_summary_swallows_epipe
  cmd = command("/tmp/demo")
  entry = { "name" => "demo", "path" => "/tmp/demo", "hive_state_path" => "/tmp/demo/.hive-state" }
  ops = Struct.new(:default_branch).new("main")
  answers = {
    "planning_agent" => "claude",
    "claude_mode" => "tmux",
    "development_agent" => "codex",
    "enabled_reviewers" => [],
    "patrol_reviewers" => [ "codex-ce-code-review" ],
    "patrol_mode" => "medium",
    "triage_bias" => "courageous",
    "budgets" => {},
    "timeouts" => {},
    "daemon_enabled" => true
  }
  cmd.define_singleton_method(:puts) { |_payload| raise Errno::EPIPE, "closed pipe" }

  assert_nil cmd.send(:emit_json_summary, entry: entry, ops: ops, answers: answers)
end

  def test_current_binary_path_resolves_hive_from_path
    Dir.mktmpdir("hive-init-unit") do |dir|
      hive = File.join(dir, "hive")
      File.write(hive, "#!/bin/sh
")
      FileUtils.chmod(0o755, hive)
      previous_program = $PROGRAM_NAME
      previous_path = ENV["PATH"]
      $PROGRAM_NAME = "hive"
      ENV["PATH"] = dir

      assert_equal hive, command.send(:current_binary_path)
      assert_nil Hive::InvokedBinary.which("missing-hive")
    ensure
      $PROGRAM_NAME = previous_program
      ENV["PATH"] = previous_path
    end
  end

  def test_current_binary_path_resolves_hv_from_path
    Dir.mktmpdir("hive-init-unit") do |dir|
      apache = File.join(dir, "apache", "hive")
      hv_dir = File.join(dir, "hive-bin")
      hv = File.join(hv_dir, "hv")
      FileUtils.mkdir_p(File.dirname(apache))
      FileUtils.mkdir_p(hv_dir)
      File.write(apache, "#!/bin/sh\n")
      File.write(hv, "#!/bin/sh\n")
      FileUtils.chmod(0o755, apache)
      FileUtils.chmod(0o755, hv)
      previous_program = $PROGRAM_NAME
      previous_path = ENV["PATH"]
      $PROGRAM_NAME = "hv"
      ENV["PATH"] = [ File.dirname(apache), hv_dir ].join(File::PATH_SEPARATOR)

      assert_equal hv, command.send(:current_binary_path)
    ensure
      $PROGRAM_NAME = previous_program
      ENV["PATH"] = previous_path
    end
  end

  def test_validate_git_repo_rejects_linked_worktree_checkout
    Dir.mktmpdir("hive-init-unit") do |dir|
      project = File.join(dir, "project")
      FileUtils.mkdir_p(project)
      original = Open3.singleton_class.instance_method(:capture3)
      ok = status(true)
      Open3.define_singleton_method(:capture3) do |*_args|
        [ File.join(dir, ".git", "worktrees", "project") + "
", "", ok ]
      end


      _out, err = capture_io do
        exit = assert_raises(SystemExit) { Hive::Commands::Init.new(project).send(:validate_git_repo!) }
        assert_equal 1, exit.status
      end

      assert_includes err, "target appears to be inside a worktree"
    ensure
      Open3.singleton_class.define_method(:capture3, original) if original
    end
  end
end
