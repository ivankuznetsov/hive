require "test_helper"
require "hive/web/capture_runtime"

class WebCaptureRuntimeTest < Minitest::Test
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
end
