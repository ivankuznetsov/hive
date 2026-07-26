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
        platform: RbConfig::CONFIG.fetch("arch")
      )
      runtime = FakeRuntime.new(entry, runtime_root)
      phases = []
      spawned_pid = nil
      spawner = lambda do |_argv, _env, chdir:|
        assert_equal File.join(source, "web"), chdir
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
      assert_equal %w[assets db], phases.map { |argv,| argv.fetch(1).split(":").first }
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

  def test_web_capture_requires_a_task_folder
    error = assert_raises(Hive::InvalidTaskPath) do
      Hive::Commands::Web.new("capture").call
    end

    assert_match(/--task-folder/, error.message)
  end
end
