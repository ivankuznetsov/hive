require "test_helper"
require "hive/web/capture_runtime"

class WebCaptureRuntimeTest < Minitest::Test
  include HiveTestHelper

  def test_environment_is_deny_by_default_and_runtime_paths_are_private
    Dir.mktmpdir("capture-runtime") do |root|
      ambient = {
        "PATH" => "/bin", "LANG" => "C.UTF-8",
        "GH_TOKEN" => "secret", "ANTHROPIC_API_KEY" => "secret",
        "TELEGRAM_BOT_TOKEN" => "secret", "SSH_AUTH_SOCK" => "/tmp/agent",
        "BUNDLE_PATH" => "/ambient", "GEM_HOME" => "/ambient",
        "HTTP_PROXY" => "http://proxy", "RUBYOPT" => "-r/evil"
      }
      runtime = Hive::Web::CaptureRuntime.new(
        source_root: "/source", runtime_root: root,
        environment: ambient, lifecycle_token: "token-123"
      )

      env = runtime.environment(bundle_path: File.join(root, "cache"), port: 4567)

      assert_equal "/bin", env.fetch("PATH")
      assert_equal "127.0.0.1", env.fetch("HIVE_WEB_CAPTURE_BIND")
      assert_equal "4567", env.fetch("HIVE_WEB_CAPTURE_PORT")
      %w[
        GH_TOKEN ANTHROPIC_API_KEY TELEGRAM_BOT_TOKEN SSH_AUTH_SOCK
        HTTP_PROXY RUBYOPT
      ].each { |name| refute env.key?(name), "#{name} leaked into capture environment" }
      refute_equal "/ambient", env.fetch("BUNDLE_PATH")
      assert env.fetch("HOME").start_with?(root)
      assert env.fetch("HIVE_HOME").start_with?(root)
    end
  end

  def test_manifest_is_reproducible_with_injected_clock_and_sorted_artifacts
    Dir.mktmpdir("capture-runtime") do |root|
      media = File.join(root, "media")
      FileUtils.mkdir_p(media)
      File.binwrite(File.join(media, "b.png"), "b")
      File.binwrite(File.join(media, "a.png"), "a")
      now = Time.utc(2026, 7, 25, 12, 0, 0)
      runtime = Hive::Web::CaptureRuntime.new(
        source_root: "/source", runtime_root: root,
        environment: {}, lifecycle_token: "token-123", clock: -> { now }
      )

      first = runtime.capture_manifest(
        task: "demo", source_sha: "a" * 40,
        lock_digests: { "web" => "b" * 64, "root" => "a" * 64 },
        cache_key: "c" * 64, command: [ "capture", "--local" ],
        fixture_ids: %w[z a], media_paths: Dir[File.join(media, "*.png")],
        status: "captured", cleanup: { "processes" => "clean", "port" => "released" }
      )
      second = runtime.capture_manifest(
        task: "demo", source_sha: "a" * 40,
        lock_digests: { "root" => "a" * 64, "web" => "b" * 64 },
        cache_key: "c" * 64, command: [ "capture", "--local" ],
        fixture_ids: %w[a z], media_paths: Dir[File.join(media, "*.png")].reverse,
        status: "captured", cleanup: { "port" => "released", "processes" => "clean" }
      )

      assert_equal JSON.generate(first), JSON.generate(second)
      assert_equal %w[a.png b.png], first.fetch("artifacts").map { |item| item.fetch("file") }
      assert first.fetch("artifacts").all? { |item| item.fetch("sha256").match?(/\A[0-9a-f]{64}\z/) }
    end
  end

  def test_stale_runtime_pid_is_never_killed_with_the_wrong_token
    Dir.mktmpdir("capture-runtime") do |root|
      File.write(File.join(root, "lifecycle.json"), JSON.generate(
        "token" => "other-token", "pid" => Process.pid, "process_start_time" => "old"
      ))
      runtime = Hive::Web::CaptureRuntime.new(
        source_root: "/source", runtime_root: root,
        environment: {}, lifecycle_token: "token-123"
      )

      error = assert_raises(Hive::Web::CaptureRuntime::OwnershipError) do
        runtime.cleanup_stale_lifecycle!
      end

      assert_match(/ownership token/, error.message)
    end
  end

  def test_nonempty_unclaimed_runtime_is_never_modified_or_cleaned
    Dir.mktmpdir("capture-runtime") do |root|
      valuable = File.join(root, "home", "valuable.txt")
      FileUtils.mkdir_p(File.dirname(valuable))
      File.write(valuable, "keep me")
      original_mode = File.stat(root).mode & 0o777
      runtime = Hive::Web::CaptureRuntime.new(
        source_root: "/source", runtime_root: root,
        environment: {}, lifecycle_token: "token-123"
      )

      error = assert_raises(Hive::Web::CaptureRuntime::OwnershipError) do
        runtime.environment(bundle_path: File.join(root, "cache"), port: 4567)
      end
      assert_match(/must be empty/, error.message)
      assert_raises(Hive::Web::CaptureRuntime::OwnershipError) do
        runtime.cleanup_runtime!
      end
      assert_equal "keep me", File.read(valuable)
      assert_equal original_mode, File.stat(root).mode & 0o777
    end
  end

  def test_prepare_claims_the_runtime_cleans_stale_state_and_resolves_the_source_bundle
    Dir.mktmpdir("capture-runtime") do |root|
      entry = Struct.new(:source_sha).new("a" * 40)
      source_bundle = Object.new
      source_bundle.define_singleton_method(:ensure!) { entry }
      runtime = Hive::Web::CaptureRuntime.new(
        source_root: "/source", runtime_root: root,
        environment: {}, lifecycle_token: "token-123",
        source_bundle: source_bundle
      )

      assert_same entry, runtime.prepare!
      assert runtime.claimed?
      assert File.file?(File.join(root, Hive::Web::CaptureRuntime::OWNER_FILE))
    end
  end

  def test_allocate_port_validates_range_selects_ephemeral_and_reports_collisions
    Dir.mktmpdir("capture-runtime") do |root|
      runtime = Hive::Web::CaptureRuntime.new(
        source_root: "/source", runtime_root: root,
        environment: {}, lifecycle_token: "token-123"
      )

      port, reservation = runtime.allocate_port(0)
      assert_operator port, :>, 0
      assert_equal port, reservation.addr.fetch(1)
      assert_raises(Hive::Web::CaptureRuntime::RuntimeError) do
        runtime.allocate_port(65_536)
      end
      error = assert_raises(Hive::Web::CaptureRuntime::RuntimeError) do
        runtime.allocate_port(port)
      end
      assert_match(/already in use/, error.message)
    ensure
      reservation&.close
    end
  end

  def test_lifecycle_receipt_is_written_and_dead_process_is_cleaned
    Dir.mktmpdir("capture-runtime") do |root|
      now = Time.utc(2026, 7, 26, 3)
      runtime = Hive::Web::CaptureRuntime.new(
        source_root: "/source", runtime_root: root,
        environment: {}, lifecycle_token: "token-123", clock: -> { now }
      )
      document = runtime.write_lifecycle!(
        pid: 999_999, process_start_time: "start", process_group: 999_999,
        port: 4567, source_sha: "a" * 40
      )

      assert_equal "token-123", document.fetch("token")
      assert_equal "2026-07-26T03:00:00.000000Z", document.fetch("created_at")
      assert File.file?(runtime.lifecycle_path)
      assert_equal(
        { "status" => "cleaned", "pid" => 999_999 },
        runtime.cleanup_stale_lifecycle!
      )
      refute File.exist?(runtime.lifecycle_path)
      assert_equal({}, runtime.send(:read_lifecycle))
    end
  end

  def test_live_stale_lifecycle_requires_proven_process_cleanup
    Dir.mktmpdir("capture-runtime") do |root|
      runtime = Hive::Web::CaptureRuntime.new(
        source_root: "/source", runtime_root: root,
        environment: {}, lifecycle_token: "token-123"
      )
      runtime.write_lifecycle!(
        pid: 1234, process_start_time: "start", process_group: 1234,
        port: 4567, source_sha: "a" * 40
      )
      killed = Hive::ProcessKill::Result.new(pid: 1234, killed: true)

      result = with_replaced_singleton_method(
        Hive::ProcessKill, :pid_alive?, ->(_pid) { true }
      ) do
        with_replaced_singleton_method(
          Hive::ProcessKill, :terminate_process_group, ->(*) { killed }
        ) { runtime.cleanup_stale_lifecycle! }
      end
      assert_equal "cleaned", result.fetch("status")

      runtime.write_lifecycle!(
        pid: 1234, process_start_time: "start", process_group: 1234,
        port: 4567, source_sha: "a" * 40
      )
      unproven = Hive::ProcessKill::Result.new(
        pid: 1234, killed: false, skipped_reason: "pid_reuse_guard"
      )
      error = with_replaced_singleton_method(
        Hive::ProcessKill, :pid_alive?, ->(_pid) { true }
      ) do
        with_replaced_singleton_method(
          Hive::ProcessKill, :terminate_process_group, ->(*) { unproven }
        ) do
          assert_raises(Hive::Web::CaptureRuntime::OwnershipError) do
            runtime.cleanup_stale_lifecycle!
          end
        end
      end
      assert_match(/ownership was not proven/, error.message)

      File.write(runtime.lifecycle_path, "[]")
      assert_raises(Hive::Web::CaptureRuntime::OwnershipError) do
        runtime.cleanup_stale_lifecycle!
      end
    end
  end

  def test_cleanup_preserves_diagnostics_on_request_and_then_removes_them
    Dir.mktmpdir("capture-runtime") do |root|
      runtime = Hive::Web::CaptureRuntime.new(
        source_root: "/source", runtime_root: root,
        environment: {}, lifecycle_token: "token-123"
      )
      env = runtime.environment(bundle_path: File.join(root, "bundle"), port: 4567)
      File.write(File.join(env.fetch("HIVE_WEB_STORAGE_DIR"), "diagnostic.log"), "boot")

      cleanup = runtime.cleanup_runtime!(preserve_diagnostics: true)
      assert_equal "cleaned", cleanup.fetch("runtime")
      assert File.file?(File.join(root, "rails-storage", "diagnostic.log"))
      refute File.exist?(File.join(root, "home"))

      runtime.cleanup_runtime!(preserve_diagnostics: false)
      refute File.exist?(File.join(root, "rails-storage"))
    end
  end

  def test_existing_owner_can_be_reclaimed_only_with_the_same_token
    Dir.mktmpdir("capture-runtime") do |root|
      first = Hive::Web::CaptureRuntime.new(
        source_root: "/source", runtime_root: root,
        environment: {}, lifecycle_token: "token-123"
      )
      first.environment(bundle_path: File.join(root, "bundle"), port: 4567)

      second = Hive::Web::CaptureRuntime.new(
        source_root: "/source", runtime_root: root,
        environment: {}, lifecycle_token: "token-123"
      )
      second.environment(bundle_path: File.join(root, "bundle"), port: 4568)
      assert second.claimed?
      assert second.send(:verify_runtime_claim!)

      foreign = Hive::Web::CaptureRuntime.new(
        source_root: "/source", runtime_root: root,
        environment: {}, lifecycle_token: "token-456"
      )
      error = assert_raises(Hive::Web::CaptureRuntime::OwnershipError) do
        foreign.environment(bundle_path: File.join(root, "bundle"), port: 4569)
      end
      assert_match(/different lifecycle token/, error.message)

      owner_path = File.join(root, Hive::Web::CaptureRuntime::OWNER_FILE)
      File.write(owner_path, JSON.generate(
        "schema" => "hive-web-capture-owner",
        "schema_version" => 1,
        "token" => "token-456"
      ))
      error = assert_raises(Hive::Web::CaptureRuntime::OwnershipError) do
        second.cleanup_runtime!
      end
      assert_match(/ownership changed/, error.message)
    end
  end

  def test_owner_receipt_validation_rejects_symlinks_bad_schema_and_missing_files
    Dir.mktmpdir("capture-runtime") do |root|
      runtime = Hive::Web::CaptureRuntime.new(
        source_root: "/source", runtime_root: root,
        environment: {}, lifecycle_token: "token-123"
      )
      real = File.join(root, "real-owner.json")
      File.write(real, JSON.generate(
        "schema" => "hive-web-capture-owner",
        "schema_version" => 1,
        "token" => "token-123"
      ))
      link = File.join(root, "owner-link.json")
      File.symlink(real, link)
      assert_raises(Hive::Web::CaptureRuntime::OwnershipError) do
        runtime.send(:read_owner, link)
      end

      File.write(real, "{}")
      assert_raises(Hive::Web::CaptureRuntime::OwnershipError) do
        runtime.send(:read_owner, real)
      end
      assert_raises(Hive::Web::CaptureRuntime::OwnershipError) do
        runtime.send(:read_owner, File.join(root, "missing.json"))
      end
    end
  end

  def test_manifest_diagnostic_is_redacted_and_default_source_bundle_is_constructed
    Dir.mktmpdir("capture-runtime") do |root|
      runtime = Hive::Web::CaptureRuntime.new(
        source_root: "/source", runtime_root: root,
        environment: {}, lifecycle_token: "token-123"
      )
      manifest = runtime.capture_manifest(
        task: "demo", source_sha: "a" * 40, lock_digests: {},
        cache_key: "b" * 64, command: [ "capture" ],
        fixture_ids: [ "fixture" ], media_paths: [], status: "failed",
        cleanup: {}, diagnostic: "token=ghp_abcdefghijklmnopqrstuvwxyz0123456789"
      )

      refute_includes manifest.fetch("diagnostic"), "ghp_"
      assert_instance_of Hive::Web::SourceBundle, runtime.send(:source_bundle)
    end
  end
end
