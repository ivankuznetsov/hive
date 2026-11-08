# frozen_string_literal: true

require "test_helper"
require "rexml/document"
require "shellwords"
require "hive/connection_contexts"
require "hive/remote/command_policy"
require "hive/commands/daemon"
require "hive/commands/daemon/service_installer"
require "hive/commands/web/service_installer"
require "hive/commands/bot/service_installer"
require "hive/commands/babysit/service_installer"

class LocalServiceContextTest < Minitest::Test
  include HiveTestHelper

  HIVE = File.expand_path("../../bin/hive", __dir__)
  SERVICES = {
    Hive::Commands::Daemon::ServiceInstaller => %w[daemon start],
    Hive::Commands::Web::ServiceInstaller => %w[web],
    Hive::Commands::Bot::ServiceInstaller => %w[bot start --foreground],
    Hive::Commands::Babysit::ServiceInstaller => %w[babysit start]
  }.freeze

  def test_systemd_service_argv_keeps_startup_local_under_a_saved_remote_context
    with_remote_selected do |home, contexts|
      SERVICES.each do |type, arguments|
        installer = type.new(host_os: "linux", home: home, binary_path: HIVE)
        content = installer.service_definition.content
        line = content.lines.find { |candidate| candidate.start_with?("ExecStart=") }
        argv = Shellwords.split(line.delete_prefix("ExecStart="))

        assert_local_startup(argv, arguments, contexts)
        if content.include?("Environment=HIVE_BIN=")
          assert_includes content, "Environment=HIVE_BIN=#{HIVE}\n"
        end
        refute File.exist?(installer.target_path), "rendering must not install a host service"
      end
    end
  end

  def test_launchd_service_argv_keeps_startup_local_under_a_saved_remote_context
    with_remote_selected do |home, contexts|
      SERVICES.each do |type, arguments|
        installer = type.new(host_os: "darwin", home: home, binary_path: HIVE)
        document = REXML::Document.new(installer.service_definition.content)
        wrapper = document.elements["plist/dict/array"].elements.map(&:text)

        assert_equal [ "/bin/sh", "-c", '[ -x "$0" ] || exit 0; exec "$0" "$@"' ], wrapper.take(3)
        assert_local_startup(wrapper.drop(3), arguments, contexts)
        refute File.exist?(installer.target_path), "rendering must not install a host service"
      end
    end
  end

  def test_daemon_code_refresh_keeps_startup_local_under_a_saved_remote_context
    with_remote_selected do |_home, contexts|
      command = Hive::Commands::Daemon.new("start", dry_run: true)
      argv = nil
      replacement = ->(*arguments) { argv = arguments; raise "exec replaced" }
      with_replaced_singleton_method(Kernel, :exec, replacement) do
        assert_raises(RuntimeError) { command.send(:reexec_with_fresh_code!) }
      end

      assert_equal [ Process.argv0, "daemon", "start", "--context", "local", "--dry-run" ], argv
      assert_local_preflight(argv, contexts)
    end
  end

  def test_babysitter_detached_restart_keeps_startup_local_under_a_saved_remote_context
    with_remote_selected do |_home, contexts|
      command = Hive::Commands::Babysit.new("restart", detach: true, dry_run: true)
      argv = nil
      replacement = ->(*arguments) { argv = arguments; raise "exec replaced" }
      with_replaced_singleton_method(Hive::InvokedBinary, :path, -> { HIVE }) do
        with_replaced_singleton_method(Kernel, :exec, replacement) do
          assert_raises(RuntimeError) { command.send(:reexec_detached_start!) }
        end
      end

      assert_equal [ HIVE, "babysit", "start", "--detach", "--context", "local", "--dry-run" ], argv
      assert_local_preflight(argv, contexts)
    end
  end

  def test_old_bare_service_requires_force_to_install_the_local_startup_arguments
    with_remote_selected do |home, contexts|
      installer = Hive::Commands::Daemon::ServiceInstaller.new(
        host_os: "linux", home: home, binary_path: HIVE, systemctl_available: false
      )
      old_content = installer.service_definition.content.sub(" --context local", "")
      FileUtils.mkdir_p(File.dirname(installer.target_path))
      File.write(installer.target_path, old_content)

      assert_equal :drifted, installer.install!(autostart: false).kind
      assert_equal old_content, File.read(installer.target_path)
      assert_equal :upgraded, installer.install!(autostart: false, force: true).kind
      line = File.readlines(installer.target_path).find { |candidate| candidate.start_with?("ExecStart=") }
      assert_local_startup(Shellwords.split(line.delete_prefix("ExecStart=")), %w[daemon start], contexts)
      assert_equal [ old_content ], Dir["#{installer.target_path}.bak-*"].map { |path| File.read(path) }
    end
  end

  private

  def with_remote_selected
    with_tmp_global_config do |home|
      contexts = Hive::ConnectionContexts.new(verifier: ->(*) { { "instance_id" => "elsewhere", "api_version" => "v1" } })
      contexts.add("elsewhere", url: "https://unreachable.invalid", token: "unused-fixture-bearer")
      contexts.use("elsewhere")
      yield home, contexts
      assert_equal "elsewhere", contexts.resolve.fetch("name"), "service startup must not change the saved client selection"
    end
  end

  def assert_local_startup(argv, arguments, contexts)
    assert_equal [ HIVE, *arguments, "--context", "local" ], argv
    assert_local_preflight(argv, contexts)
  end

  def assert_local_preflight(argv, contexts)
    invocation = Hive::Remote::CommandPolicy.preflight!(argv.drop(1), contexts: contexts, stderr: StringIO.new)
    assert_equal "local", invocation.context.fetch("type")
    refute invocation.handled?
    refute_includes invocation.argv, "--context"
  end
end
