require "test_helper"
require "hive/llm_wiki_bootstrap"
require "open3"
require "securerandom"

class LlmWikiSystemdUserTest < Minitest::Test
  ROOT = "/tmp/wiki test".freeze

  def test_user_manager_passes_the_exact_working_directory_and_project_argument
    skip "real LLM-wiki recorder requires the declared systemd user gate" unless ENV["HIVE_REQUIRE_SYSTEMD_USER_GATE"] == "1"

    assert_match(/linux/i, RbConfig::CONFIG["host_os"])
    assert File.directory?(ENV.fetch("XDG_RUNTIME_DIR")), "missing user runtime directory"
    assert File.file?("/sys/fs/cgroup/cgroup.controllers"), "cgroup v2 is required"
    @manager_env = { "HOME" => ENV.fetch("HIVE_SYSTEMD_USER_HOME") }
    manager!("show-environment")
    manager!("daemon-reload")
    @unit = "hive-wiki-probe-#{SecureRandom.hex(12)}.service"
    @source = File.join(ROOT, @unit)
    @link = File.join(@manager_env.fetch("HOME"), ".config/systemd/user", @unit)
    assert_equal "not-found", load_state
    refute File.exist?(@link) || File.symlink?(@link), "occupied probe link #{@link}"

    begin
      Dir.mkdir(ROOT, 0o700)
    rescue Errno::EEXIST
      flunk "#{ROOT.inspect} is occupied. Inspect the entry and move or remove it if appropriate before retrying."
    end
    begin
      refute File.exist?(@source) || File.symlink?(@source)
      child = File.join(ROOT, "apostrophe' $$ ${NAME} %t %% é\tquote\" \\\\ \\x20")
      Dir.mkdir(child)
      [ ROOT, child ].each_with_index do |project, index|
        runner = File.join(project, "recorder")
        File.write(runner, <<~RUBY_SCRIPT)
          #!#{RbConfig.ruby}
          require "json"
          File.write("observed.json", JSON.generate([Dir.pwd, ARGV, ENV.fetch("NAME")]))
        RUBY_SCRIPT
        File.chmod(0o755, runner)
        service = Hive::LlmWikiBootstrap::Scheduler.systemd_service(project, @unit, refresh_script: runner)
        # Retain the completed oneshot long enough to inspect its condition and exit status.
        service = service.sub("Type=oneshot", "Type=oneshot\nRemainAfterExit=yes\nEnvironment=NAME=expanded-value")
        File.write(@source, service)
        _, error, status = Open3.capture3(@manager_env, "systemd-analyze", "--user", "verify", @source)
        assert status.success?, "systemd-analyze verify failed: #{error}"
        manager!("link", @source) if index.zero?
        assert_equal @source, File.readlink(@link)
        manager!("daemon-reload")
        assert_run(project)
        manager!("stop", @unit)
      end
    ensure
      cleanup_probe
    end
  end

  private

  def assert_run(project)
    record = File.join(project, "observed.json")
    refute_path_exists record
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    loop do
      manager!("start", @unit)
      props = manager!("show", @unit, "-p", "ConditionResult", "-p", "Result", "-p", "ExecMainCode", "-p", "ExecMainStatus")
              .lines(chomp: true).to_h { |line| line.split("=", 2) }
      assert_equal "yes", props.fetch("ConditionResult")
      assert_equal "success", props.fetch("Result")
      assert_equal "1", props.fetch("ExecMainCode"), "main process did not exit normally"
      assert_equal "0", props.fetch("ExecMainStatus")
      break if File.exist?(record)
      flunk "no fresh recorder output in 10s; check contention on %t/llm-wiki-refresh.lock" if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      manager!("stop", @unit)
      sleep 2.5
    end
    assert_equal [ project, [ "--project", project, "--drain" ], "expanded-value" ], JSON.parse(File.read(record))
  end

  def load_state
    out, err, status = Open3.capture3(@manager_env, "systemctl", "--user", "show", @unit, "-p", "LoadState", "--value")
    assert status.success? || (status.exitstatus == 4 && out.chomp == "not-found"), err
    out.chomp
  end

  def manager!(*args)
    out, err, status = Open3.capture3(@manager_env, "systemctl", "--user", *args)
    assert status.success?, "systemctl --user #{args.join(' ')}: #{err}"
    out
  end

  def cleanup_probe
    linked = File.symlink?(@link) && File.readlink(@link) == @source
    begin
      manager!("stop", @unit) if linked && load_state == "loaded"
    ensure
      File.unlink(@link) if linked
      FileUtils.remove_entry_secure(ROOT)
      manager!("daemon-reload") if linked
      refute File.exist?(@link) || File.symlink?(@link)
      refute_path_exists ROOT
      assert_equal "not-found", load_state
    end
  end
end
