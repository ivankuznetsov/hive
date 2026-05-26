require "test_helper"
require "hive/commands/init"
require "fileutils"

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
