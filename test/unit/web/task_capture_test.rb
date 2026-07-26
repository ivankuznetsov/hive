require "test_helper"
require "hive/web/task_capture"

class WebTaskCaptureTest < Minitest::Test
  FakeBundle = Struct.new(:entry, :calls) do
    def ensure!
      self.calls += 1
      entry
    end
  end

  def test_publishes_media_and_manifest_only_after_teardown_and_head_recheck
    Dir.mktmpdir("hive-task-capture") do |root|
      source = File.join(root, "source")
      task_folder = File.join(
        root, ".hive-state", "stages", "7-artifacts", "demo-task"
      )
      FileUtils.mkdir_p([ source, task_folder ])
      head = "a" * 40
      source_entry = Hive::Web::SourceBundle::Entry.new(
        cache_key: "b" * 64,
        cache_root: File.join(root, "bundle"),
        bundle_path: File.join(root, "bundle", "gems"),
        source_sha: head,
        lock_digests: { "root" => "c" * 64, "web" => "d" * 64 },
        ruby_engine: RUBY_ENGINE,
        ruby_version: RUBY_VERSION,
        platform: RbConfig::CONFIG.fetch("arch")
      )
      browser_entry = Hive::Web::BrowserBundle::Entry.new(
        cache_key: "e" * 64,
        cache_root: File.join(root, "browser"),
        node_modules_path: File.join(root, "browser", "node_modules"),
        playwright_cli: File.join(root, "browser", "playwright"),
        browsers_path: File.join(root, "browser", "browsers"),
        package_digests: {
          "package" => "f" * 64, "package_lock" => "0" * 64
        },
        node_version: "v26.2.0",
        platform: RbConfig::CONFIG.fetch("arch")
      )
      source_bundle = FakeBundle.new(source_entry, 0)
      browser_bundle = FakeBundle.new(browser_entry, 0)
      capture = Hive::Web::TaskCapture.new(
        task_folder: task_folder,
        source_bundle: source_bundle,
        browser_bundle: browser_bundle,
        environment: { "PATH" => ENV.fetch("PATH", "") }
      )
      stopped = []
      capture.define_singleton_method(:capture_requirement) do
        { "result" => "required", "implementation_head" => head }
      end
      capture.define_singleton_method(:owned_source_root) { source }
      capture.define_singleton_method(:start_server) do |**|
        { base_url: "http://127.0.0.1:4567" }
      end
      capture.define_singleton_method(:stop_server!) { |session| stopped << session }
      capture.define_singleton_method(:seed_fixture!) do |**|
        { "project" => "fixture", "task" => "fixture-task" }
      end
      capture.define_singleton_method(:record_browser!) do |screenshot:, video_directory:, **|
        File.binwrite(screenshot, Hive::Web::TaskCapture::PNG_SIGNATURE + "image")
        FileUtils.mkdir_p(video_directory)
        video = File.join(video_directory, "recording.webm")
        File.binwrite(video, "playable")
        {
          "video_path" => video,
          "accessibility_assertions" => [ "Board heading is visible" ]
        }
      end
      capture.define_singleton_method(:validate_media!) { |_screenshot, _video| true }

      manifest = capture.call

      assert_equal "captured", manifest.fetch("status")
      assert_equal 2, manifest.fetch("artifacts").length
      assert_equal 2, source_bundle.calls,
                   "source must be validated before boot and again before publication"
      assert_equal 1, browser_bundle.calls
      assert_equal 1, stopped.length
      assert File.file?(File.join(task_folder, "media", "capture-manifest.json"))
      manifest.fetch("artifacts").each do |artifact|
        assert File.file?(File.join(task_folder, "media", artifact.fetch("file")))
      end
      refute Dir.glob(File.join(task_folder, "media", ".capture-*")).any?
    end
  end
end
