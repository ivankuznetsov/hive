require "test_helper"
require "fileutils"
require "json"
require "open3"
require "socket"
require "tmpdir"
require "hive/modules/migration/candidate_execution_sandbox"

class ModulesMigrationCandidateExecutionSandboxTest <
    Minitest::Test
  include HiveTestHelper
  SANDBOX =
    Hive::Modules::Migration::CandidateExecutionSandbox

  def test_both_lanes_use_one_closed_mount_profile
    with_workspace do |context|
      commands = {}
      [ false, true ].each do |network|
        sandbox(context, network: network) do |launch|
          commands[network] = launch.command
          assert_equal !network, launch.network_isolated
          assert_match(/\A[0-9a-f]{64}\z/, launch.profile_sha256)
          assert_equal "/", launch.host_cwd
          assert_equal(
            "/qualification/cases/case-one/sandbox/hive-home",
            launch.environment.fetch("HIVE_HOME")
          )
          refute launch.environment.key?(
            "QUALIFICATION_AMBIENT_SECRET"
          )
        end
      end

      isolated = commands.fetch(false)
      shared = commands.fetch(true)
      assert_includes isolated, "--unshare-all"
      assert_includes isolated, "--disable-userns"
      refute_includes isolated, "--share-net"
      assert_includes shared, "--share-net"
      refute_equal isolated, shared
      refute command_pair?(isolated, "--ro-bind", "/", "/")
      refute command_pair?(
        isolated,
        "--bind",
        context.fetch(:workspace),
        "/qualification"
      )
      refute command_pair?(
        isolated,
        "--ro-bind",
        context.fetch(:workspace),
        "/qualification"
      )
      refute_includes isolated.join("\0"), context.fetch(:control)
      refute_includes isolated.join("\0"), "other-case"
      assert_includes(
        isolated,
        "/qualification/inputs/scenarios/case-one.yml"
      )
      assert_includes(
        isolated,
        "/qualification/cases/case-one"
      )
    end
  end

  def test_real_namespace_hides_host_and_other_cases_but_persists_case_output
    with_workspace do |context|
      with_env(
        "QUALIFICATION_AMBIENT_SECRET" => "must-not-leak"
      ) do
        result = run_sandbox(context, network: false)
        assert result.fetch(:status).success?, result.fetch(:stderr)
      end
      output = JSON.parse(
        File.binread(
          File.join(context.fetch(:case), "output.json")
        )
      )

      assert_equal false, output.fetch("ambient_secret")
      assert_equal false, output.fetch("host_control")
      assert_equal false, output.fetch("other_case")
      assert_equal false, output.fetch("host_pid")
      assert_equal true, output.fetch("request")
      assert_equal true, output.fetch("scenario")
    end
  end

  def test_network_toggle_is_the_only_connectivity_difference
    with_workspace do |context|
      server = TCPServer.new("127.0.0.1", 0)
      port = server.addr.fetch(1)
      context[:argv] = [ port.to_s ]

      isolated = run_sandbox(context, network: false)
      assert isolated.fetch(:status).success?,
             isolated.fetch(:stderr)
      assert_equal(
        false,
        JSON.parse(
          File.binread(
            File.join(context.fetch(:case), "network.json")
          )
        ).fetch("connected")
      )
      File.unlink(
        File.join(context.fetch(:case), "network.json")
      )

      accepted = Thread.new do
        socket = server.accept
        socket.close
      end
      shared = run_sandbox(context, network: true)
      assert shared.fetch(:status).success?, shared.fetch(:stderr)
      assert accepted.join(2), "shared network did not connect"
      assert_equal(
        true,
        JSON.parse(
          File.binread(
            File.join(context.fetch(:case), "network.json")
          )
        ).fetch("connected")
      )
    ensure
      server&.close
      accepted&.kill
      accepted&.join
    end
  end

  def test_target_drift_is_rejected_after_candidate_exit
    with_workspace do |context|
      error = assert_raises(Hive::ConfigError) do
        sandbox(context, network: false) do |_launch|
          File.binwrite(
            File.join(context.fetch(:source), "lib", "drift.rb"),
            "drift\n"
          )
          File.chmod(
            0o600,
            File.join(context.fetch(:source), "lib", "drift.rb")
          )
        end
      end

      assert_equal(
        "patrol qualification candidate target changed",
        error.message
      )
    end
  end

  private

  def with_workspace
    Dir.mktmpdir("candidate-sandbox") do |root|
      File.chmod(0o700, root)
      workspace = File.join(root, "workspace")
      source = File.join(workspace, "targets", "source")
      installed =
        File.join(workspace, "targets", "installed")
      case_root = File.join(workspace, "cases", "case-one")
      other_case =
        File.join(workspace, "cases", "other-case")
      request =
        File.join(workspace, "requests", "case-one.json")
      scenario = File.join(
        workspace,
        "inputs",
        "scenarios",
        "case-one.yml"
      )
      control = File.join(root, "trusted-control")
      [
        File.join(source, "bin"),
        File.join(source, "lib"),
        File.join(source, "config"),
        File.join(source, "schemas"),
        File.join(source, "templates"),
        File.join(source, "modules", "patrol"),
        File.join(source, "modules", "architecture-patrol"),
        File.join(installed, "bin"),
        File.join(installed, "rubygems-bin"),
        case_root,
        other_case,
        File.dirname(request),
        File.dirname(scenario),
        control
      ].each do |path|
        FileUtils.mkdir_p(path, mode: 0o700)
        chmod_parents(path, stop: root)
      end
      File.binwrite(request, "{}")
      File.binwrite(scenario, "case: one\n")
      File.binwrite(File.join(other_case, "secret"), "other\n")
      File.binwrite(File.join(control, "catalog.json"), "hidden\n")
      [ request, scenario,
        File.join(other_case, "secret"),
        File.join(control, "catalog.json") ].each do |path|
        File.chmod(0o600, path)
      end
      executable = File.join(source, "bin", "hive")
      File.binwrite(
        executable,
        executable_body(
          control: control,
          host_pid: Process.pid
        )
      )
      File.chmod(0o700, executable)
      context = {
        root: root,
        workspace: workspace,
        source: source,
        installed: installed,
        case: case_root,
        executable: executable,
        control: control,
        argv: []
      }
      yield context
    end
  end

  def sandbox(context, network:, &block)
    SANDBOX.new.call(
      executable: context.fetch(:executable),
      argv: context.fetch(:argv),
      workspace: context.fetch(:workspace),
      source_root: context.fetch(:source),
      installed_root: context.fetch(:installed),
      case_root: context.fetch(:case),
      request_ref: "requests/case-one.json",
      scenario_ref: "inputs/scenarios/case-one.yml",
      network: network,
      credentials: {},
      hive_home:
        File.join(
          context.fetch(:case),
          "sandbox",
          "hive-home"
        ),
      &block
    )
  end

  def run_sandbox(context, network:)
    value = nil
    sandbox(context, network: network) do |launch|
      stdout, stderr, status = Open3.capture3(
        launch.environment,
        *launch.command,
        chdir: launch.host_cwd,
        unsetenv_others: true
      )
      value = {
        stdout: stdout,
        stderr: stderr,
        status: status
      }
    end
    value
  end

  def executable_body(control:, host_pid:)
    <<~RUBY
      #!#{RbConfig.ruby}
      require "json"
      require "socket"
      if ARGV.empty?
        output = {
          "ambient_secret" =>
            ENV.key?("QUALIFICATION_AMBIENT_SECRET"),
          "host_control" =>
            File.exist?(#{control.inspect}),
          "other_case" =>
            File.exist?(
              "/qualification/cases/other-case/secret"
            ),
          "host_pid" => File.exist?("/proc/#{host_pid}"),
          "request" =>
            File.file?(
              "/qualification/requests/case-one.json"
            ),
          "scenario" =>
            File.file?(
              "/qualification/inputs/scenarios/case-one.yml"
            )
        }
        File.binwrite(
          "/qualification/cases/case-one/output.json",
          JSON.generate(output)
        )
      else
        connected = begin
          socket = Socket.tcp(
            "127.0.0.1",
            Integer(ARGV.fetch(0)),
            connect_timeout: 0.2
          )
          socket.close
          true
        rescue SystemCallError, IOError
          false
        end
        File.binwrite(
          "/qualification/cases/case-one/network.json",
          JSON.generate("connected" => connected)
        )
      end
    RUBY
  end

  def chmod_parents(path, stop:)
    current = path
    while current.start_with?("#{stop}/")
      File.chmod(0o700, current)
      current = File.dirname(current)
    end
    File.chmod(0o700, stop)
  end

  def command_pair?(command, flag, source, destination)
    command.each_cons(3).any? do |items|
      items == [ flag, source, destination ]
    end
  end
end
