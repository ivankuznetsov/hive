require "test_helper"
require "hive/artifacts/capture_toolkit"

class ArtifactsCaptureToolkitCoverageGapsTest < Minitest::Test
  include HiveTestHelper

  Toolkit = Hive::Artifacts::CaptureToolkit
  FakeBrowser = Data.define(
    :cache_root, :agent_browser_cli, :browser_executable, :agent_browser_version,
    :browsers_path, :skills_path, :cache_key
  )

  def test_prepare_normalizes_proxy_and_os_start_failures
    Dir.mktmpdir("hive-capture-toolkit-errors") do |root|
      toolkit = prepared_toolkit
      replacement = ->(**) { raise Hive::Artifacts::CaptureProxy::ProxyError, "proxy" }
      error = with_replaced_singleton_method(
        Hive::Artifacts::CaptureProxy, :new, replacement
      ) do
        assert_raises(Hive::ConfigError) { prepare_visual(toolkit, root) }
      end
      assert_match(/origin is unavailable/, error.message)

      os_error = Toolkit.new(tool_resolver: ->(*) { raise Errno::EIO, "broken" })
      error = assert_raises(Hive::ConfigError) { prepare_visual(os_error, root) }
      assert_match(/could not start/, error.message)
    end
  end

  def test_managed_web_server_default_and_error_paths
    Dir.mktmpdir("hive-capture-toolkit-server") do |root|
      source = hive_web_source(root)
      fake = Object.new
      fake.define_singleton_method(:start!) { { "app_port" => 1234 } }
      captured = nil
      toolkit = Toolkit.new
      result = with_replaced_singleton_method(
        Hive::Artifacts::ManagedWebServer, :new, ->(**attributes) {
          captured = attributes
          fake
        }
      ) do
        toolkit.send(
          :start_managed_web_server, source_root: source, source_sha: "a" * 40,
          writable_root: File.join(root, "work")
        )
      end
      assert_equal 1234, result.fetch("app_port")
      assert_equal source, captured.fetch(:source_root)

      failing = Object.new
      failing.define_singleton_method(:start!) do
        raise Hive::Artifacts::ManagedWebServer::ServerError, "not ready"
      end
      toolkit = Toolkit.new(web_server_factory: ->(**) { failing })
      error = assert_raises(Hive::ConfigError) do
        toolkit.send(
          :start_managed_web_server, source_root: source, source_sha: "a" * 40,
          writable_root: File.join(root, "work")
        )
      end
      assert_match(/not ready/, error.message)
    end
  end

  def test_browser_bundle_callable_and_bootstrap_error_are_normalized
    entry = browser_entry
    callable = -> { Object.new.tap { |bundle| bundle.define_singleton_method(:ensure!) { entry } } }
    assert_same entry, Toolkit.new(browser_bundle: callable).send(:resolve_browser_bundle)

    failing = Object.new
    failing.define_singleton_method(:ensure!) do
      raise Hive::Web::BrowserBundle::BootstrapError, "bad cache"
    end
    error = assert_raises(Hive::ConfigError) do
      Toolkit.new(browser_bundle: failing).send(:resolve_browser_bundle)
    end
    assert_match(/bad cache/, error.message)
  end

  def test_codex_runtime_resolution_requires_a_compatible_native_binary
    toolkit = Toolkit.new
    assert_raises(Hive::ConfigError) { toolkit.send(:resolve_codex_runtime, nil) }

    Dir.mktmpdir("hive-codex-runtime") do |root|
      bin = File.join(root, "codex")
      File.binwrite(bin, "ELF fixture")
      FileUtils.chmod(0o755, bin)
      profile = fake_profile(bin)
      assert_equal [ root ], toolkit.send(:resolve_codex_runtime, profile)

      script = File.join(root, "script")
      File.write(script, "#!/bin/sh\n")
      FileUtils.chmod(0o755, script)
      assert_raises(Hive::ConfigError) do
        toolkit.send(:resolve_codex_runtime, fake_profile(script))
      end

      path_profile = fake_profile("codex")
      with_env("PATH" => "#{root}#{File::PATH_SEPARATOR}") do
        assert_equal [ root ], toolkit.send(:resolve_codex_runtime, path_profile)
      end

      realpath = File.method(:realpath)
      with_replaced_singleton_method(
        File, :realpath, ->(path) { path == bin ? raise(Errno::EACCES) : realpath.call(path) }
      ) do
        assert_raises(Hive::ConfigError) do
          toolkit.send(:resolve_codex_runtime, profile)
        end
      end
    end

    incompatible = fake_profile("codex")
    compatible = incompatible.with_overrides("min_version" => "0.138.0")
    compatible.define_singleton_method(:check_version!) do
      raise Hive::AgentError, "old"
    end
    incompatible.define_singleton_method(:with_overrides) { |_| compatible }
    error = assert_raises(Hive::ConfigError) do
      toolkit.send(:resolve_codex_runtime, incompatible)
    end
    assert_match(/0\.138\.0\+/, error.message)
  end

  def test_native_browser_command_reports_failure_timeout_and_missing_binary
    toolkit = Toolkit.new
    assert_nil toolkit.send(:run_browser_command, {}, [ RbConfig.ruby, "-e", "exit" ])
    assert_raises(Hive::ConfigError) do
      toolkit.send(:run_browser_command, {}, [ RbConfig.ruby, "-e", "exit 2" ])
    end
    assert_raises(Hive::ConfigError) do
      toolkit.send(:run_browser_command, {}, [ "/missing/agent-browser" ])
    end

    toolkit.define_singleton_method(:terminate_process_group) { |_| nil }
    with_replaced_singleton_method(Timeout, :timeout, ->(*) { raise Timeout::Error }) do
      assert_raises(Hive::ConfigError) do
        toolkit.send(:run_browser_command, {}, [ RbConfig.ruby, "-e", "sleep 0.1" ])
      end
    end

    fresh = Toolkit.new
    kills = []
    with_replaced_singleton_method(Process, :kill, ->(*args) { kills << args }) do
      fresh.send(:terminate_process_group, 99)
    end
    assert_equal [ [ "TERM", -99 ], [ "KILL", -99 ] ], kills
    with_replaced_singleton_method(Process, :kill, ->(*) { raise Errno::ESRCH }) do
      assert_nil fresh.send(:terminate_process_group, 99)
    end
  end

  def test_browser_daemon_receipt_is_owned_and_teardown_is_bounded
    Dir.mktmpdir("hive-capture-daemon") do |root|
      namespace = "n-test"
      pid_path = File.join(root, "daemon.pid")
      pid = Process.pid
      File.write(pid_path, "#{pid}\n")
      toolkit = Toolkit.new
      toolkit.instance_variable_set(:@browser_daemon, {
        pid_path: pid_path, executable: RbConfig.ruby,
        socket_root: root, namespace: namespace
      })
      realpath = File.method(:realpath)
      binread = File.method(:binread)
      expected_environment = [
        "AGENT_BROWSER_SOCKET_DIR=#{root}",
        "AGENT_BROWSER_NAMESPACE=#{namespace}"
      ].join("\0")
      with_replaced_singleton_method(
        File, :realpath,
        ->(path) { path.to_s.start_with?("/proc/") || path == RbConfig.ruby ? "/resolved/codex" : realpath.call(path) }
      ) do
        with_replaced_singleton_method(
          File, :binread,
          ->(path, *args) { path.to_s.end_with?("/environ") ? expected_environment : binread.call(path, *args) }
        ) do
          with_replaced_singleton_method(Process, :getpgid, ->(*) { pid }) do
            assert_equal pid, toolkit.send(:browser_daemon_pid)
          end
        end
      end

      with_replaced_singleton_method(Process, :kill, ->(*) { raise Errno::ESRCH }) do
        refute toolkit.send(:process_alive?, pid)
      end
      with_replaced_singleton_method(Process, :kill, ->(*) { true }) do
        assert toolkit.send(:process_alive?, pid)
      end

      File.write(pid_path, "invalid\n")
      assert_raises(Hive::ConfigError) { toolkit.send(:browser_daemon_pid) }
      File.unlink(pid_path)
      assert_nil toolkit.send(:browser_daemon_pid)
    end
  end

  def test_daemon_forced_kill_invalid_receipts_and_socket_cleanup
    toolkit = Toolkit.new
    toolkit.instance_variable_set(:@browser_daemon, { pid_path: "/missing" })
    toolkit.define_singleton_method(:browser_daemon_pid) { 123 }
    alive = [ true, false, true ]
    toolkit.define_singleton_method(:process_alive?) { |_| alive.shift || false }
    kills = []
    with_replaced_singleton_method(Process, :kill, ->(signal, pid) { kills << [ signal, pid ] }) do
      toolkit.send(:stop_browser_daemon)
    end
    assert_includes kills, [ "TERM", -123 ]
    assert_includes kills, [ "KILL", -123 ]

    failing_stop = Toolkit.new
    failing_stop.instance_variable_set(:@browser_daemon, { pid_path: "/unused" })
    failing_stop.define_singleton_method(:browser_daemon_pid) { 123 }
    with_replaced_singleton_method(Process, :kill, ->(*) { raise Errno::ESRCH }) do
      assert_nil failing_stop.send(:stop_browser_daemon)
    end

    Dir.mktmpdir("hive-capture-receipt") do |root|
      receipt = File.join(root, "pid")
      File.write(receipt, "#{Process.pid}\n")
      toolkit = Toolkit.new
      toolkit.instance_variable_set(:@browser_daemon, {
        pid_path: receipt, executable: RbConfig.ruby,
        socket_root: root, namespace: "wrong"
      })
      assert_raises(Hive::ConfigError) { toolkit.send(:browser_daemon_pid) }

      link = File.join(root, "pid-link")
      File.symlink(receipt, link)
      toolkit.instance_variable_set(:@browser_daemon, {
        pid_path: link, executable: RbConfig.ruby,
        socket_root: root, namespace: "wrong"
      })
      assert_raises(Hive::ConfigError) { toolkit.send(:browser_daemon_pid) }
    end

    Dir.mktmpdir("hive-capture-sockets") do |root|
      directory = File.join(root, "directory")
      Dir.mkdir(directory)
      toolkit.instance_variable_set(:@browser_socket_root, directory)
      toolkit.send(:remove_browser_socket_root)
      refute_path_exists directory

      target = File.join(root, "target")
      File.write(target, "target")
      link = File.join(root, "link")
      File.symlink(target, link)
      toolkit.instance_variable_set(:@browser_socket_root, link)
      toolkit.send(:remove_browser_socket_root)
      refute_path_exists link
      assert_path_exists target

      toolkit.instance_variable_set(:@browser_socket_root, File.join(root, "missing"))
      assert_nil toolkit.send(:remove_browser_socket_root)
    end

    toolkit.define_singleton_method(:close) { raise Hive::ConfigError, "cleanup" }
    assert_nil toolkit.send(:close_after_prepare_error)
  end

  private

  def browser_entry
    FakeBrowser.new(
      cache_root: "/managed/cache", agent_browser_cli: "/managed/agent-browser",
      browser_executable: "/managed/chrome", agent_browser_version: "0.34.0",
      browsers_path: "/managed/browsers", skills_path: "/managed/skills",
      cache_key: "b" * 64
    )
  end

  def prepared_toolkit
    bundle = Object.new
    entry = browser_entry
    bundle.define_singleton_method(:ensure!) { entry }
    Toolkit.new(
      browser_bundle: bundle, tool_resolver: ->(name) { "/usr/bin/#{name}" },
      codex_runtime_resolver: ->(*) { [ "/managed/runtime" ] },
      browser_command_runner: ->(*) { }
    )
  end

  def prepare_visual(toolkit, root)
    toolkit.prepare!(
      kinds: [ "screenshot" ], task_root: root, source_root: root,
      source_sha: "a" * 40, writable_root: File.join(root, "work")
    )
  end

  def hive_web_source(root)
    source = File.join(root, "source")
    %w[bin web web/bin].each { |path| FileUtils.mkdir_p(File.join(source, path)) }
    %w[bin/hive web/Gemfile web/bin/rails].each do |path|
      File.write(File.join(source, path), "fixture")
    end
    source
  end

  def fake_profile(bin)
    profile = Object.new
    profile.define_singleton_method(:name) { :codex }
    profile.define_singleton_method(:bin) { bin }
    profile.define_singleton_method(:check_version!) { true }
    profile.define_singleton_method(:with_overrides) { |_| profile }
    profile
  end
end
