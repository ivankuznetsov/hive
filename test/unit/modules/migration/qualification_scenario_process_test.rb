require "test_helper"
require "json"
require "rbconfig"
require "hive/modules/migration/qualification_scenario_process"

class ModulesMigrationQualificationScenarioProcessTest <
    Minitest::Test
  include HiveTestHelper

  PROCESS =
    Hive::Modules::Migration::QualificationScenarioProcess

  def test_executes_exact_target_in_closed_networkless_environment
    with_process_workspace do |workspace, installed, executable|
      probe = File.join(workspace, "probe.json")
      write_executable(
        executable,
        <<~RUBY
          require "json"
          require "socket"
          blocked = begin
            Socket.tcp("1.1.1.1", 53, connect_timeout: 0.2).close
            false
          rescue SystemCallError, IOError
            true
          end
          File.binwrite(
            ARGV.fetch(0),
            JSON.generate(
              "secret_present" => ENV.key?("QUALIFICATION_AMBIENT_SECRET"),
              "home" => ENV.fetch("HOME"),
              "hive_home" => ENV.fetch("HIVE_HOME"),
              "gem_home" => ENV.fetch("GEM_HOME"),
              "network_blocked" => blocked
            )
          )
        RUBY
      )

      with_env("QUALIFICATION_AMBIENT_SECRET" => "must-not-leak") do
        result = PROCESS.new.call(
          executable: executable,
          argv: [ probe ],
          workspace: workspace,
          installed_root: installed,
          timeout_seconds: 5,
          network: false,
          credentials: {}
        )

        assert_equal "passed", result.status
        assert_equal 0, result.exit_status
        assert_equal true, result.network_isolated
      end
      data = JSON.parse(File.binread(probe))
      assert_equal false, data.fetch("secret_present")
      assert_equal true, data.fetch("network_blocked")
      assert_equal File.join(workspace, "runtime", "home"),
                   data.fetch("home")
      assert_equal File.join(workspace, "sandbox", "hive-home"),
                   data.fetch("hive_home")
      assert_equal installed, data.fetch("gem_home")
    end
  end

  def test_bounds_streams_and_returns_only_digests
    with_process_workspace do |workspace, installed, executable|
      write_executable(
        executable,
        <<~RUBY
          STDOUT.write("o" * 100_000)
          STDERR.write("e" * 100_000)
        RUBY
      )

      result = PROCESS.new(output_limit: 1_024).call(
        executable: executable,
        argv: [],
        workspace: workspace,
        installed_root: installed,
        timeout_seconds: 5,
        network: true,
        credentials: {}
      )

      assert_equal 100_000, result.stdout.fetch("bytes")
      assert_equal 100_000, result.stderr.fetch("bytes")
      assert_equal true, result.stdout.fetch("truncated")
      assert_equal true, result.stderr.fetch("truncated")
      assert_match(
        /\A[0-9a-f]{64}\z/,
        result.stdout.fetch("sha256")
      )
      refute result.stdout.key?("content")
    end
  end

  def test_confines_hive_home_and_runtime_to_one_scenario
    with_process_workspace do |workspace, installed, executable|
      case_root = File.join(workspace, "cases", "case-one")
      FileUtils.mkdir_p(case_root, mode: 0o700)
      File.chmod(0o700, File.join(workspace, "cases"))
      File.chmod(0o700, case_root)
      hive_home =
        File.join(case_root, "sandbox", "hive-home")
      probe = File.join(workspace, "probe.json")
      write_executable(
        executable,
        <<~RUBY
          require "json"
          File.binwrite(
            ARGV.fetch(0),
            JSON.generate(
              "home" => ENV.fetch("HOME"),
              "hive_home" => ENV.fetch("HIVE_HOME"),
              "custody" =>
                ENV.fetch("HIVE_QUALIFICATION_CUSTODY_ROOT")
            )
          )
        RUBY
      )

      result = PROCESS.new.call(
        executable: executable,
        argv: [ probe ],
        workspace: workspace,
        installed_root: installed,
        timeout_seconds: 5,
        network: true,
        credentials: {},
        hive_home: hive_home
      )

      assert_equal "passed", result.status
      data = JSON.parse(File.binread(probe))
      assert_equal hive_home, data.fetch("hive_home")
      assert_equal File.join(case_root, "runtime", "home"),
                   data.fetch("home")
      assert_equal File.join(case_root, "runtime", "custody"),
                   data.fetch("custody")
      refute File.exist?(File.join(workspace, "runtime"))
    end
  end

  def test_timeout_terminates_the_foreground_group
    with_process_workspace do |workspace, installed, executable|
      pid_path = File.join(workspace, "child.pid")
      write_executable(
        executable,
        <<~RUBY
          child = spawn(
            RbConfig.ruby,
            "-e",
            "sleep 30",
            pgroup: Process.getpgrp
          )
          File.binwrite(ARGV.fetch(0), child.to_s)
          sleep 30
        RUBY
      )

      result = PROCESS.new.call(
        executable: executable,
        argv: [ pid_path ],
        workspace: workspace,
        installed_root: installed,
        timeout_seconds: 0.2,
        network: true,
        credentials: {}
      )

      assert_equal "failed", result.status
      assert_equal true, result.timed_out
      child_pid = Integer(File.binread(pid_path))
      refute process_alive?(child_pid)
    end
  end

  def test_unbound_detached_custody_fails_closed_without_leaking_process
    with_process_workspace do |workspace, installed, executable|
      pid_path = File.join(workspace, "detached.pid")
      library = File.expand_path("../../../../lib", __dir__)
      write_executable(
        executable,
        <<~RUBY
          \$LOAD_PATH.unshift(#{library.inspect})
          require "json"
          require "hive/lock"
          child = fork do
            STDIN.reopen(File::NULL)
            STDOUT.reopen(File::NULL, "w")
            STDERR.reopen(File::NULL, "w")
            Process.setsid
            sleep 30
          end
          identity = nil
          100.times do
            begin
              start = Hive::Lock.process_start_time(child)
              session = Process.getsid(child)
              group = Process.getpgid(child)
              if !start.to_s.empty? && session == child &&
                 group == child
                identity = {
                  "pid" => child,
                  "process_group_id" => group,
                  "session_id" => session,
                  "start_fingerprint" => start.to_s
                }
              end
            rescue Errno::ESRCH
              nil
            end
            break if identity
            sleep 0.01
          end
          raise "identity unavailable" unless identity
          attempt_id =
            "11111111-1111-4111-8111-111111111111"
          custody = {
            "attempt_id" => attempt_id,
            "schema" =>
              "hive-patrol-qualification-process-custody",
            "schema_version" => 1,
            "wrapper" => identity
          }
          custody_path = File.join(
            ENV.fetch("HIVE_QUALIFICATION_CUSTODY_ROOT"),
            "\#{attempt_id}.json"
          )
          File.binwrite(
            custody_path,
            "\#{JSON.generate(custody)}\\n"
          )
          File.chmod(0o600, custody_path)
          File.binwrite(ARGV.fetch(0), child.to_s)
        RUBY
      )

      error = assert_raises(Hive::ConfigError) do
        PROCESS.new.call(
          executable: executable,
          argv: [ pid_path ],
          workspace: workspace,
          installed_root: installed,
          timeout_seconds: 5,
          network: true,
          credentials: {}
        )
      end

      assert_match(/custody is unbound/, error.message)
      detached_pid = Integer(File.binread(pid_path))
      refute process_alive?(detached_pid)
    end
  end

  private

  def with_process_workspace
    with_tmp_dir do |root|
      File.chmod(0o700, root)
      workspace = File.join(root, "workspace")
      installed = File.join(workspace, "installed")
      executable =
        File.join(workspace, "candidate", "bin", "hive")
      FileUtils.mkdir_p(
        File.dirname(executable),
        mode: 0o700
      )
      FileUtils.mkdir_p(installed, mode: 0o700)
      yield workspace, installed, executable
    end
  end

  def write_executable(path, body)
    File.binwrite(
      path,
      "#!#{RbConfig.ruby}\n#{body}"
    )
    File.chmod(0o700, path)
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end
end
