require "test_helper"
require "stringio"
require "hive/commands/web"
require "hive/commands/web/capture_server"
require "hive/web/source_bundle"
require "hive/web/task_capture"

class CommandsWebTest < Minitest::Test
  include HiveTestHelper

  class FakeRuntime
    attr_reader :prepares, :lifecycle, :cleanups

    def initialize(entry, runtime_root)
      @entry = entry
      @runtime_root = runtime_root
      @prepares = 0
      @cleanups = 0
    end

    def prepare!
      @prepares += 1
      @entry
    end

    def allocate_port(port)
      server = TCPServer.new("127.0.0.1", port)
      [ server.addr.fetch(1), server ]
    end

    def environment(bundle_path:, port:)
      {
        "PATH" => "/usr/bin:/bin",
        "BUNDLE_PATH" => bundle_path,
        "HIVE_WEB_STORAGE_DIR" => File.join(@runtime_root, "storage"),
        "HIVE_WEB_CAPTURE_PORT" => port.to_s
      }
    end

    def write_lifecycle!(**fields)
      @lifecycle = fields
    end

    def cleanup_runtime!(preserve_diagnostics:)
      raise "capture server must remove its ephemeral database" if preserve_diagnostics

      @cleanups += 1
    end
  end

  def test_capture_server_emits_readiness_and_cleans_its_owned_process_group
    Dir.mktmpdir("capture-command") do |root|
      source = File.join(root, "source")
      runtime_root = File.join(root, "runtime")
      FileUtils.mkdir_p(File.join(source, "web"))
      entry = Hive::Web::SourceBundle::Entry.new(
        cache_key: "c" * 64,
        cache_root: File.join(root, "cache"),
        bundle_path: File.join(root, "cache", "gems"),
        source_sha: "a" * 40,
        lock_digests: { "root" => "b" * 64, "web" => "d" * 64 },
        ruby_engine: RUBY_ENGINE,
        ruby_version: RUBY_VERSION,
        platform: RbConfig::CONFIG.fetch("arch"),
        bundler_executable: Gem.bin_path("bundler", "bundle", "= 2.7.2")
      )
      runtime = FakeRuntime.new(entry, runtime_root)
      phases = []
      spawned_pid = nil
      spawned_argv = nil
      spawner = lambda do |argv, _env, chdir:|
        assert_equal File.join(source, "web"), chdir
        spawned_argv = argv
        spawned_pid = Process.spawn(
          RbConfig.ruby, "-e", "sleep 30",
          pgroup: true, in: File::NULL, out: File::NULL, err: File::NULL
        )
      end
      reader, writer = IO.pipe
      writer.close
      output = StringIO.new
      command = Hive::Commands::Web::CaptureServer.new(
        source_root: source,
        runtime_root: runtime_root,
        lifecycle_token: "capture-123",
        control_io: reader,
        output: output,
        error: StringIO.new,
        runtime: runtime,
        phase_runner: ->(argv, _env, chdir:) { phases << [ argv, chdir ]; true },
        spawner: spawner,
        readiness_probe: ->(url) { url.start_with?("http://127.0.0.1:") }
      )

      receipt = command.call

      payload = JSON.parse(output.string)
      assert_equal "hive-web-capture-runtime", payload.fetch("schema")
      assert_equal "capture-123", payload.fetch("lifecycle_id")
      assert_equal entry.source_sha, payload.fetch("source_sha")
      assert_equal entry.lock_digests, payload.fetch("lock_digests")
      assert_equal spawned_pid, runtime.lifecycle.fetch(:pid)
      assert_equal 2, runtime.prepares
      assert_equal 1, runtime.cleanups
      expected_prefix = [ RbConfig.ruby, entry.bundler_executable, "exec", "bin/rails" ]
      assert_equal %w[assets db], phases.map { |argv,| argv.fetch(4).split(":").first }
      phases.each { |argv,| assert_equal expected_prefix, argv.take(4) }
      assert_equal expected_prefix, spawned_argv.take(4)
      assert_equal "server", spawned_argv.fetch(4)
      assert_equal payload.fetch("port"), receipt.port
      refute Hive::ProcessKill.pid_alive?(spawned_pid)
    ensure
      reader&.close
      if spawned_pid && Hive::ProcessKill.pid_alive?(spawned_pid)
        Process.kill("KILL", -spawned_pid) rescue nil
        Process.waitpid(spawned_pid) rescue nil
      end
    end
  end

  def test_web_capture_server_requires_explicit_owned_inputs
    error = assert_raises(Hive::InvalidTaskPath) do
      Hive::Commands::Web.new(
        "capture-server",
        source_root: nil,
        runtime_root: "/tmp/runtime",
        lifecycle_token: nil
      ).call
    end

    assert_match(/--source-root/, error.message)
    assert_match(/--lifecycle-token/, error.message)
  end

  def test_web_capture_publishes_the_task_manifest_as_json
    output = StringIO.new
    manifest = {
      "schema" => "hive-artifact-capture",
      "task" => "demo-task",
      "artifacts" => [ { "file" => "capture.png" } ]
    }
    fake = Struct.new(:manifest) { def call = manifest }.new(manifest)
    calls = []
    replacement = lambda do |task_folder:, source_root:, **|
      calls << [ task_folder, source_root ]
      fake
    end

    result = with_replaced_singleton_method(
      Hive::Web::TaskCapture, :new, replacement
    ) do
      Hive::Commands::Web.new(
        "capture",
        task_folder: "/tmp/task",
        source_root: "/tmp/source",
        json: true,
        output: output
      ).call
    end

    assert_equal manifest, result
    assert_equal [ [ "/tmp/task", "/tmp/source" ] ], calls
    assert_equal manifest, JSON.parse(output.string)
  end

  def test_web_capture_reports_a_human_readable_summary
    output = StringIO.new
    manifest = {
      "schema" => "hive-artifact-capture",
      "task" => "demo-task",
      "artifacts" => [ { "file" => "capture.png" }, { "file" => "capture.webm" } ]
    }
    fake = Struct.new(:manifest) { def call = manifest }.new(manifest)

    with_replaced_singleton_method(
      Hive::Web::TaskCapture, :new, ->(**) { fake }
    ) do
      Hive::Commands::Web.new(
        "capture", task_folder: "/tmp/task", source_root: "/tmp/source",
        output: output
      ).call
    end

    assert_match(/captured 2 local artifacts for demo-task/, output.string)
    assert_match(%r{/tmp/task/media/capture-manifest\.json}, output.string)
  end

  def test_web_capture_server_delegates_with_default_control_channel
    calls = []
    fake = Object.new
    fake.define_singleton_method(:call) { :captured }
    replacement = lambda do |**options|
      calls << options
      fake
    end

    result = with_replaced_singleton_method(
      Hive::Commands::Web::CaptureServer, :new, replacement
    ) do
      Hive::Commands::Web.new(
        "capture-server",
        source_root: "/tmp/source",
        runtime_root: "/tmp/runtime",
        lifecycle_token: "token-123",
        environment: {},
        output: StringIO.new,
        error: StringIO.new
      ).call
    end

    assert_equal :captured, result
    assert_same $stdin, calls.first.fetch(:control_io)
    assert_equal 0, calls.first.fetch(:port)
  end

  def test_capture_control_fd_accepts_an_open_integer_and_rejects_invalid_values
    reader, writer = IO.pipe
    command = Hive::Commands::Web.new(
      "capture-server",
      source_root: "/tmp/source",
      runtime_root: "/tmp/runtime",
      lifecycle_token: "token-123",
      control_fd: reader.fileno.to_s
    )

    control = command.send(:capture_control_io)
    assert_equal reader.fileno, control.fileno

    invalid = Hive::Commands::Web.new("capture-server", control_fd: "not-an-integer")
    assert_raises(Hive::InvalidTaskPath) { invalid.send(:capture_control_io) }
  ensure
    control&.close unless control&.closed?
    reader&.close unless reader&.closed?
    writer&.close unless writer&.closed?
  end

  def test_capture_server_rejects_source_head_changes_during_bootstrap
    Dir.mktmpdir("capture-command") do |root|
      source = File.join(root, "source")
      FileUtils.mkdir_p(File.join(source, "web"))
      entry_class = Hive::Web::SourceBundle::Entry
      first = entry_class.new(
        cache_key: "c" * 64, cache_root: "/cache", bundle_path: "/cache/gems",
        source_sha: "a" * 40, lock_digests: {},
        ruby_engine: RUBY_ENGINE, ruby_version: RUBY_VERSION,
        platform: RbConfig::CONFIG.fetch("arch"), bundler_executable: "/bundle"
      )
      second = first.with(source_sha: "b" * 40)
      prepares = [ first, second ]
      runtime = Object.new
      runtime.define_singleton_method(:prepare!) { prepares.shift }
      runtime.define_singleton_method(:allocate_port) do |_port|
        server = TCPServer.new("127.0.0.1", 0)
        [ server.addr.fetch(1), server ]
      end
      runtime.define_singleton_method(:environment) do |bundle_path:, port:|
        { "HIVE_WEB_STORAGE_DIR" => "/storage" }
      end
      runtime.define_singleton_method(:claimed?) { false }
      command = Hive::Commands::Web::CaptureServer.new(
        source_root: source, runtime_root: File.join(root, "runtime"),
        lifecycle_token: "token-123", runtime: runtime,
        phase_runner: ->(*) { true }
      )

      error = assert_raises(Hive::Commands::Web::CaptureServer::BootstrapError) do
        command.call
      end
      assert_match(/source HEAD changed/, error.message)
    end
  end

  def test_capture_server_default_phase_runner_and_spawner
    Dir.mktmpdir("capture-command") do |root|
      error_log = File.open(File.join(root, "error.log"), "w")
      command = Hive::Commands::Web::CaptureServer.new(
        source_root: root, runtime_root: File.join(root, "runtime"),
        lifecycle_token: "token-123", error: error_log
      )

      assert command.send(
        :run_phase, [ RbConfig.ruby, "-e", "exit 0" ], {}, chdir: root
      )
      pid = command.send(
        :spawn_server, [ RbConfig.ruby, "-e", "sleep 0.01" ], {}, chdir: root
      )
      Process.waitpid(pid)

      error = assert_raises(Hive::Commands::Web::CaptureServer::BootstrapError) do
        command.send(:spawn_server, [ File.join(root, "missing") ], {}, chdir: root)
      end
      assert_match(/spawn failed/, error.message)
    ensure
      error_log&.close
    end
  end

  def test_capture_server_readiness_detects_exit_and_timeout
    exit_command = Hive::Commands::Web::CaptureServer.new(
      source_root: "/tmp/source", runtime_root: "/tmp/runtime",
      lifecycle_token: "token-123", readiness_probe: ->(*) { false },
      boot_timeout_sec: 1
    )
    exited = Process.spawn("/bin/sh", "-c", "exit 7")
    sleep 0.1
    error = assert_raises(Hive::Commands::Web::CaptureServer::ReadinessError) do
      exit_command.send(:wait_until_ready!, exited, 65_000)
    end
    assert_match(/exited before readiness/, error.message)

    timeout_command = Hive::Commands::Web::CaptureServer.new(
      source_root: "/tmp/source", runtime_root: "/tmp/runtime",
      lifecycle_token: "token-123", readiness_probe: ->(*) { false },
      boot_timeout_sec: 0
    )
    sleeper = Process.spawn(RbConfig.ruby, "-e", "sleep 30")
    error = assert_raises(Hive::Commands::Web::CaptureServer::ReadinessError) do
      timeout_command.send(:wait_until_ready!, sleeper, 65_000)
    end
    assert_match(/not ready within/, error.message)
  ensure
    if sleeper && Hive::ProcessKill.pid_alive?(sleeper)
      Process.kill("KILL", sleeper)
      Process.waitpid(sleeper) rescue nil
    end
  end

  def test_capture_server_readiness_retries_before_success
    probes = 0
    command = Hive::Commands::Web::CaptureServer.new(
      source_root: "/tmp/source", runtime_root: "/tmp/runtime",
      lifecycle_token: "token-123",
      readiness_probe: lambda do |_url|
        probes += 1
        probes >= 2
      end,
      boot_timeout_sec: 1
    )
    sleeper = Process.spawn(RbConfig.ruby, "-e", "sleep 30")

    assert_nil command.send(:wait_until_ready!, sleeper, 65_000)
    assert_equal 2, probes
  ensure
    if sleeper && Hive::ProcessKill.pid_alive?(sleeper)
      Process.kill("KILL", sleeper)
      Process.waitpid(sleeper) rescue nil
    end
  end

  def test_capture_server_http_probe_and_closed_control_channel
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr.fetch(1)
    responder = Thread.new do
      socket = server.accept
      socket.readpartial(4096)
      socket.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
      socket.close
    end
    command = Hive::Commands::Web::CaptureServer.new(
      source_root: "/tmp/source", runtime_root: "/tmp/runtime",
      lifecycle_token: "token-123"
    )

    assert command.send(:ready?, "http://127.0.0.1:#{port}/health")
    responder.join(2)
    server.close
    refute command.send(:ready?, "http://127.0.0.1:#{port}/health")

    reader, writer = IO.pipe
    reader.close
    process = Process.spawn(RbConfig.ruby, "-e", "sleep 30")
    command_with_closed_control = Hive::Commands::Web::CaptureServer.new(
      source_root: "/tmp/source", runtime_root: "/tmp/runtime",
      lifecycle_token: "token-123", control_io: reader
    )
    assert_nil command_with_closed_control.send(:wait_for_shutdown, process)
  ensure
    writer&.close unless writer&.closed?
    if process && Hive::ProcessKill.pid_alive?(process)
      Process.kill("KILL", process)
      Process.waitpid(process) rescue nil
    end
    server&.close unless server&.closed?
    responder&.kill
    responder&.join(2)
  end

  def test_capture_server_teardown_accepts_not_alive_and_rejects_unproven_cleanup
    command = Hive::Commands::Web::CaptureServer.new(
      source_root: "/tmp/source", runtime_root: "/tmp/runtime",
      lifecycle_token: "token-123"
    )
    result = Hive::ProcessKill::Result.new(
      pid: 123, killed: false, skipped_reason: "not_alive"
    )
    process = Process.spawn(RbConfig.ruby, "-e", "exit 0")
    sleep 0.02
    with_replaced_singleton_method(
      Hive::ProcessKill, :terminate_process_group, ->(*) { result }
    ) do
      assert_nil command.send(:teardown!, process, "start")
    end

    result = Hive::ProcessKill::Result.new(
      pid: 123, killed: false, skipped_reason: "pid_reuse_guard"
    )
    process = Process.spawn(RbConfig.ruby, "-e", "exit 0")
    sleep 0.02
    error = with_replaced_singleton_method(
      Hive::ProcessKill, :terminate_process_group, ->(*) { result }
    ) do
      assert_raises(Hive::Commands::Web::CaptureServer::TeardownError) do
        command.send(:teardown!, process, "start")
      end
    end
    assert_match(/pid_reuse_guard/, error.message)
  end

  def test_web_capture_requires_a_task_folder
    error = assert_raises(Hive::InvalidTaskPath) do
      Hive::Commands::Web.new("capture").call
    end

    assert_match(/--task-folder/, error.message)
  end
end
