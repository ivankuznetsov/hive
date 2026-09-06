require "test_helper"
require "hive/artifacts/capture_toolkit"
require "hive/agent_support/pi"

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

      os_error = Toolkit.new(
        tool_resolver: ->(*) { raise Errno::EIO, "broken" },
        runtime_resolver: ->(*) { [ "/managed/codex-runtime" ] }
      )
      error = assert_raises(Hive::ConfigError) { prepare_visual(os_error, root) }
      assert_match(/could not start/, error.message)
    end
  end

  def test_prepare_normalizes_capture_gateway_failures
    Dir.mktmpdir("hive-capture-toolkit-gateway") do |root|
      replacement = lambda do |**|
        raise Hive::Artifacts::BrowserGateway::GatewayError, "gateway"
      end
      error = with_replaced_singleton_method(
        Hive::Artifacts::BrowserGateway, :new, replacement
      ) do
        assert_raises(Hive::ConfigError) { prepare_visual(prepared_toolkit, root) }
      end
      assert_match(/managed capture gateway is unavailable/, error.message)
    end
  end

  def test_browser_preflight_cleans_up_socket_and_listener_failures
    toolkit = Toolkit.new
    socket_closed = false
    socket = Object.new
    socket.define_singleton_method(:closed?) { socket_closed }
    socket.define_singleton_method(:close) { socket_closed = true }
    socket.define_singleton_method(:write) { |_| raise Errno::EPIPE }
    io_select = ->(*) { false }
    with_replaced_singleton_method(IO, :select, io_select) do
      assert_nil toolkit.send(:serve_browser_preflight, socket)
    end
    assert socket_closed

    listener_closed = false
    listener = Object.new
    listener.define_singleton_method(:listen) { |_| raise Errno::EIO }
    listener.define_singleton_method(:close) { listener_closed = true }
    with_replaced_singleton_method(TCPServer, :new, ->(*) { listener }) do
      assert_raises(Errno::EIO) { toolkit.send(:start_browser_preflight) }
    end
    assert listener_closed

    failed_listener = Object.new
    failed_listener.define_singleton_method(:close) { raise Errno::EIO }
    toolkit.instance_variable_set(
      :@browser_preflight, { server: failed_listener, thread: Object.new }
    )
    assert_nil toolkit.send(:close_browser_preflight)
    assert_nil toolkit.instance_variable_get(:@browser_preflight)
  end

  def test_browser_preflight_serves_a_request_and_releases_its_listener
    toolkit = Toolkit.new
    preflight = toolkit.send(:start_browser_preflight)

    socket = TCPSocket.new("127.0.0.1", preflight.fetch(:app_port))
    socket.write("GET / HTTP/1.1\r\nHost: evidence.invalid\r\n\r\n")
    response = socket.read

    assert_includes response, "HTTP/1.1 200 OK"
    assert_includes response, "<!doctype html>"
  ensure
    socket&.close
    toolkit&.send(:close_browser_preflight)
  end

  def test_browser_preflight_ignores_waiting_and_closed_request_reads
    toolkit = Toolkit.new
    socket_closed = false
    socket = Object.new
    reads = [ :wait_readable, nil ]
    socket.define_singleton_method(:read_nonblock) { |*| reads.shift }
    socket.define_singleton_method(:write) { |_| nil }
    socket.define_singleton_method(:closed?) { socket_closed }
    socket.define_singleton_method(:close) { socket_closed = true }

    with_replaced_singleton_method(IO, :select, ->(*) { true }) do
      assert_nil toolkit.send(:serve_browser_preflight, socket)
    end

    assert socket_closed
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
    policy = Hive::AgentSupport.for(:codex)::ArtifactPolicy
    assert_raises(Hive::ConfigError) { policy.runtime_roots(nil) }

    Dir.mktmpdir("hive-codex-runtime") do |root|
      bin = File.join(root, "codex")
      File.binwrite(bin, "ELF fixture")
      FileUtils.chmod(0o755, bin)
      profile = fake_profile(bin)
      assert_equal [ root ], policy.runtime_roots(profile)

      script = File.join(root, "script")
      File.write(script, "#!/bin/sh\n")
      FileUtils.chmod(0o755, script)
      assert_raises(Hive::ConfigError) do
        policy.runtime_roots(fake_profile(script))
      end

      path_profile = fake_profile("codex")
      with_env("PATH" => "#{root}#{File::PATH_SEPARATOR}") do
        assert_equal [ root ], policy.runtime_roots(path_profile)
      end

      realpath = File.method(:realpath)
      with_replaced_singleton_method(
        File, :realpath, ->(path) { path == bin ? raise(Errno::EACCES) : realpath.call(path) }
      ) do
        assert_raises(Hive::ConfigError) do
          policy.runtime_roots(profile)
        end
      end
    end

    incompatible = fake_profile("codex")
    compatible = incompatible.with_overrides(
      "min_version" => policy::MINIMUM_VERSION
    )
    compatible.define_singleton_method(:check_version!) do
      raise Hive::AgentError, "old"
    end
    incompatible.define_singleton_method(:with_overrides) { |_| compatible }
    error = assert_raises(Hive::ConfigError) do
      policy.runtime_roots(incompatible)
    end
    assert_includes error.message, "#{policy::MINIMUM_VERSION}+"
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

  def test_browser_bootstrap_gets_a_longer_deadline_than_close
    toolkit = Toolkit.new
    deadlines = []
    timeout = lambda do |seconds, &block|
      deadlines << seconds
      block.call
    end

    with_replaced_singleton_method(Timeout, :timeout, timeout) do
      toolkit.send(:run_browser_command, {}, [ RbConfig.ruby, "-e", "exit" ])
      toolkit.send(:run_browser_command, {}, [ RbConfig.ruby, "-e", "exit", "close" ])
    end

    assert_equal [
      Toolkit::BROWSER_BOOTSTRAP_TIMEOUT_SECONDS,
      Toolkit::BROWSER_CLOSE_TIMEOUT_SECONDS
    ], deadlines
    assert_operator deadlines.first, :>, deadlines.last
  end

  def test_browser_receipt_describes_the_controller_owned_sandbox
    proxy = Struct.new(:hostname, :proxy_url, :origin, :app_port).new(
      "evidence.invalid", "http://127.0.0.1:9999", "http://evidence.invalid", 4321
    )
    toolkit = Toolkit.new(hive_executable: "/opt/hive/bin/hive")
    toolkit.instance_variable_set(:@capture_proxy, proxy)

    receipt = toolkit.send(:browser_receipt, browser_entry, { "app_port" => 4321 }, "/tmp/output")

    assert_equal "agent-browser", receipt.fetch("driver")
    assert_equal "/tmp/output", receipt.fetch("output_root")
    assert_equal [ RbConfig.ruby, "/opt/hive/bin/hive", "evidence", "browser" ],
                 receipt.fetch("argv_prefix")
    assert_equal "http://127.0.0.1:4321", receipt.fetch("app_endpoint")
    assert_equal "producer-workspace", receipt.dig("sandbox", "driver")
    assert_match(/limited proxy/, receipt.dig("sandbox", "network"))
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

  def test_capture_request_dispatch_and_project_provider_admission_are_fail_closed
    toolkit = Toolkit.new
    toolkit.instance_variable_set(:@task_root, "/task")
    toolkit.instance_variable_set(:@source_sha, "a" * 40)
    project_provider = {
      "kind" => "screenshot",
      "source" => {
        "type" => "project_provider", "manifest_path" => "media/manifest.json"
      },
      "representations" => [ { "path" => "media/proof.png" } ]
    }
    replacement = ->(value, **) { value }
    with_replaced_singleton_method(
      Hive::Artifacts::OutcomeEvidence::Proof, :admit!, replacement
    ) do
      assert toolkit.verify_captures!([ project_provider ])

      invalid = Marshal.load(Marshal.dump(project_provider))
      invalid.fetch("representations").first["path"] = "work/proof.png"
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        toolkit.send(:verify_project_provider!, invalid)
      end
    end

    assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
      toolkit.verify_captures!([ { "kind" => "screenshot" } ])
    end

    unavailable = toolkit.send(:handle_capture_request, "operation" => "browser")
    assert_equal 64, unavailable.fetch("status")
    assert_match(/unavailable/, unavailable.fetch("error"))

    calls = []
    gateway = Object.new
    gateway.define_singleton_method(:call) do |argv|
      calls << argv
      { "ok" => true, "status" => 0 }
    end
    toolkit.instance_variable_set(:@browser_gateway, gateway)
    assert_equal true,
                 toolkit.send(
                   :handle_capture_request, "operation" => "browser", "argv" => [ "snapshot" ]
                 ).fetch("ok")
    assert_equal [ [ "snapshot" ] ], calls
    assert_equal 64,
                 toolkit.send(:handle_capture_request, "operation" => "unknown").fetch("status")
    assert_match(/invalid/,
                 toolkit.send(:handle_capture_request, {}).fetch("error"))
    assert_match(
      /terminal capture request is invalid/,
      toolkit.send(
        :handle_capture_request, "operation" => "terminal", "name" => "../bad", "argv" => []
      ).fetch("error")
    )
  end

  def test_controller_capture_receipts_detect_invalid_files_digests_and_races
    Dir.mktmpdir("hive-controller-capture") do |root|
      toolkit = Toolkit.new
      toolkit.instance_variable_set(:@task_root, root)

      empty = File.join(root, "empty.png")
      File.write(empty, "")
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        toolkit.send(:record_capture!, "path" => empty, "media_type" => "image/png")
      end

      changed = File.join(root, "changed.png")
      File.binwrite(changed, "png")
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        toolkit.send(
          :record_capture!, "path" => changed, "media_type" => "image/png",
          "sha256" => "0" * 64
        )
      end

      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        toolkit.send(
          :record_capture!, "path" => File.join(root, "missing.png"),
          "media_type" => "image/png"
        )
      end
      refute toolkit.send(
        :capture_file_matches?, "missing.png", "bytes" => 1, "sha256" => "0" * 64
      )

      short = File.join(root, "short.png")
      File.binwrite(short, "png")
      assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
        toolkit.send(:bounded_digest, short, 4)
      end

      pathname = Object.new
      pathname.define_singleton_method(:relative_path_from) { |_| raise ArgumentError, "roots" }
      with_replaced_singleton_method(Pathname, :new, ->(*) { pathname }) do
        assert_raises(Hive::Artifacts::OutcomeEvidence::StoreError) do
          toolkit.send(:task_relative_path, short)
        end
      end
    end
  end

  def test_browser_state_cleanup_unlinks_symlinks_and_tolerates_absence
    Dir.mktmpdir("hive-browser-state-cleanup") do |root|
      target = File.join(root, "target")
      File.write(target, "keep")
      link = File.join(root, "state-link")
      File.symlink(target, link)
      toolkit = Toolkit.new
      toolkit.instance_variable_set(:@browser_state_root, link)
      toolkit.send(:remove_browser_state_root)
      refute_path_exists link
      assert_path_exists target
      assert_nil toolkit.instance_variable_get(:@browser_state_root)

      toolkit.instance_variable_set(:@browser_state_root, File.join(root, "missing"))
      assert_nil toolkit.send(:remove_browser_state_root)
      assert_nil toolkit.instance_variable_get(:@browser_state_root)
    end
  end

  # The terminal-capture sandbox seam is injected by tests that must run where
  # bubblewrap is absent, so its production default is proven here instead.
  def test_default_project_sandbox_factory_builds_the_real_sandbox
    Dir.mktmpdir("hive-capture-toolkit-sandbox-default") do |root|
      source = File.join(root, "source")
      FileUtils.mkdir_p(source)
      factory = Toolkit.new.instance_variable_get(:@project_sandbox_factory)

      sandbox = factory.call(source_root: source, environment: {})

      assert_instance_of Hive::Artifacts::ProjectCommandSandbox, sandbox
      assert sandbox.close
    end
  end

  # The managed project runtime root is created for Pi producers and removed on
  # teardown. Both halves are private lifecycle seams with no public caller a
  # unit test can reach, so they are driven directly.
  def test_project_runtime_root_is_owner_checked_across_its_lifetime
    toolkit = Toolkit.new
    toolkit.send(:prepare_project_runtime_root)
    root = toolkit.instance_variable_get(:@project_runtime_root)

    assert_path_exists root
    assert_equal 0o700, File.stat(root).mode & 0o7777

    toolkit.send(:remove_project_runtime_root)

    refute_path_exists root
    assert_nil toolkit.instance_variable_get(:@project_runtime_root)
  end

  def test_visual_pi_producer_prepares_a_project_runtime_root_without_a_managed_server
    Dir.mktmpdir("hive-pi-project-runtime") do |root|
      toolkit = prepared_toolkit
      policy = Object.new
      policy.define_singleton_method(:cleanup!) { true }
      runtime_root = nil

      with_replaced_singleton_method(
        Hive::AgentSupport::Pi::Runtime, :compile_evidence_actor, ->(**) { policy }
      ) do
        toolkit.prepare!(
          kinds: [ "screenshot" ], task_root: root, source_root: root,
          source_sha: "a" * 40, writable_root: File.join(root, "work"),
          producer_profile: Hive::AgentProfiles.lookup(:pi)
        )
        runtime_root = toolkit.instance_variable_get(:@project_runtime_root)
        assert_path_exists runtime_root
      end

      toolkit.close
      refute_path_exists runtime_root
    end
  end

  def test_project_runtime_root_teardown_refuses_a_substituted_root
    Dir.mktmpdir("hive-project-runtime-swap") do |root|
      target = File.join(root, "target")
      FileUtils.mkdir_p(target)
      swapped = File.join(root, "swapped")
      File.symlink(target, swapped)
      toolkit = Toolkit.new
      toolkit.instance_variable_set(:@project_runtime_root, swapped)

      error = assert_raises(Hive::ConfigError) do
        toolkit.send(:remove_project_runtime_root)
      end

      assert_match(/runtime ownership changed/, error.message)
      assert_path_exists target
    end
  end

  def test_project_runtime_root_teardown_tolerates_an_already_removed_root
    toolkit = Toolkit.new
    toolkit.instance_variable_set(
      :@project_runtime_root, File.join(Dir.tmpdir, "hive-project-runtime-gone-#{Process.pid}")
    )

    assert_nil toolkit.send(:remove_project_runtime_root)
    assert_nil toolkit.instance_variable_get(:@project_runtime_root)
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
      runtime_resolver: ->(*) { [ "/managed/runtime" ] },
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
