require "test_helper"
require "json"
require "hive/config"
require "hive/markers"
require "hive/screenote_uploader"
require "hive/stages/artifacts"
require "hive/task"

class StagesArtifactsTest < Minitest::Test
  def test_markerless_artifacts_stage_spawns_agent_and_returns_complete_marker
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      folder = File.join(dir, ".hive-state", "stages", "7-artifacts", "demo-260522-aaaa")
      FileUtils.mkdir_p(folder)
      task = Hive::Task.new(folder)

      calls = with_stubbed_artifacts_spawn do
        Hive::Stages::Artifacts.run!(task, {})
      end
      result = calls.fetch(:result)

      assert_equal({ commit: "artifacts_collected", status: :complete }, result)
      assert_equal 1, calls.fetch(:spawns).length
      assert File.exist?(task.state_file)
      assert_equal :complete, Hive::Markers.current(task.state_file).name
    end
  end

  def test_complete_artifacts_stage_is_idempotent
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      folder = File.join(dir, ".hive-state", "stages", "7-artifacts", "demo-260522-aaaa")
      FileUtils.mkdir_p(folder)
      task = Hive::Task.new(folder)
      Hive::Markers.set(task.state_file, :complete)

      assert_equal({ commit: nil, status: :complete }, Hive::Stages::Artifacts.run!(task, {}))
      assert_equal :complete, Hive::Markers.current(task.state_file).name
    end
  end

  def test_push_manifest_media_uploads_only_png_and_jpeg_stills
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      media_dir = File.join(task.folder, "media")
      FileUtils.mkdir_p(media_dir)
      File.binwrite(File.join(media_dir, "01-home.png"), "png")
      File.binwrite(File.join(media_dir, "02-state.jpg"), "jpg")
      File.binwrite(File.join(media_dir, "demo.gif"), "gif")
      write_manifest(task, {
        "schema" => 1,
        "status" => "captured",
        "surface" => "ui",
        "items" => [
          { "file" => "01-home.png", "type" => "still", "caption" => "Home", "push_to_screenote" => true, "screenote_url" => nil },
          { "file" => "02-state.jpg", "type" => "still", "caption" => "State", "push_to_screenote" => true, "screenote_url" => nil },
          { "file" => "demo.gif", "type" => "gif", "caption" => "Motion", "push_to_screenote" => false, "screenote_url" => nil }
        ]
      })
      uploader = StubUploader.new

      Hive::Stages::Artifacts.push_manifest_media_to_screenote(task, uploader: uploader)

      assert_equal [ "01-home.png", "02-state.jpg" ], uploader.files
      manifest = JSON.parse(File.read(Hive::Stages::Artifacts.media_manifest_path(task)))
      assert_equal "https://screenote.test/01-home.png", manifest.dig("items", 0, "screenote_url")
      assert_equal "https://screenote.test/02-state.jpg", manifest.dig("items", 1, "screenote_url")
      assert_nil manifest.dig("items", 2, "screenote_url")
    end
  end

  def test_push_manifest_media_skips_existing_urls_and_nil_upload_results
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      media_dir = File.join(task.folder, "media")
      FileUtils.mkdir_p(media_dir)
      File.binwrite(File.join(media_dir, "01-home.png"), "png")
      File.binwrite(File.join(media_dir, "02-state.png"), "png")
      write_manifest(task, {
        "schema" => 1,
        "status" => "captured",
        "surface" => "ui",
        "items" => [
          { "file" => "01-home.png", "type" => "still", "caption" => "Home", "push_to_screenote" => true, "screenote_url" => "https://already.test/s/1" },
          { "file" => "02-state.png", "type" => "still", "caption" => "State", "push_to_screenote" => true, "screenote_url" => nil }
        ]
      })
      uploader = StubUploader.new(nil_result_for: "02-state.png")

      Hive::Stages::Artifacts.push_manifest_media_to_screenote(task, uploader: uploader)

      assert_equal [ "02-state.png" ], uploader.files
      manifest = JSON.parse(File.read(Hive::Stages::Artifacts.media_manifest_path(task)))
      assert_equal "https://already.test/s/1", manifest.dig("items", 0, "screenote_url")
      assert_nil manifest.dig("items", 1, "screenote_url")
    end
  end

  def test_push_manifest_media_ignores_skipped_and_failed_manifests
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      uploader = StubUploader.new

      %w[skipped failed].each do |status|
        write_manifest(task, { "schema" => 1, "status" => status, "surface" => "none", "items" => [] })
        Hive::Stages::Artifacts.push_manifest_media_to_screenote(task, uploader: uploader)
      end

      assert_empty uploader.files
    end
  end

  def test_push_manifest_media_without_screenote_config_is_noop
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      media_dir = File.join(task.folder, "media")
      FileUtils.mkdir_p(media_dir)
      File.binwrite(File.join(media_dir, "01-home.png"), "png")
      write_manifest(task, {
        "schema" => 1,
        "status" => "captured",
        "items" => [
          { "file" => "01-home.png", "push_to_screenote" => true, "screenote_url" => nil }
        ]
      })

      Hive::Stages::Artifacts.push_manifest_media_to_screenote(task, screenote_config: { "base_url" => "", "api_token" => "" })

      manifest = JSON.parse(File.read(Hive::Stages::Artifacts.media_manifest_path(task)))
      assert_nil manifest.dig("items", 0, "screenote_url")
    end
  end

  def test_push_manifest_media_swallows_corrupt_manifest
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      media_dir = File.join(task.folder, "media")
      FileUtils.mkdir_p(media_dir)
      File.write(File.join(media_dir, "manifest.json"), "{")

      _out, err = capture_io do
        Hive::Stages::Artifacts.push_manifest_media_to_screenote(task, uploader: StubUploader.new)
      end

      assert_includes err, "media manifest is not valid JSON"
    end
  end

  def test_complete_agent_run_pushes_manifest_after_marker
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      media_dir = File.join(task.folder, "media")
      FileUtils.mkdir_p(media_dir)
      File.binwrite(File.join(media_dir, "01-home.png"), "png")
      write_manifest(task, {
        "schema" => 1,
        "status" => "captured",
        "items" => [
          { "file" => "01-home.png", "push_to_screenote" => true, "screenote_url" => nil }
        ]
      })

      uploader = StubUploader.new
      original_spawn = Hive::Stages::Artifacts.method(:spawn_artifacts_agent)
      original_load = Hive::Config.method(:load_global_screenote)
      original_new = Hive::ScreenoteUploader.method(:new)
      Hive::Stages::Artifacts.define_singleton_method(:spawn_artifacts_agent) do |spawn_task, _cfg, _prompt, _profile|
        Hive::Markers.set(spawn_task.state_file, :complete)
      end
      # Drive the real screenote_uploader factory through the documented config
      # seam (load_global_screenote -> ScreenoteUploader.new) instead of
      # overriding the private factory: a valid global config plus a stubbed
      # uploader exercises the production path without coupling to internals.
      Hive::Config.define_singleton_method(:load_global_screenote) do
        { "base_url" => "https://screenote.test", "api_token" => "secret" }
      end
      # Accept any constructor signature: a new kwarg on ScreenoteUploader.new
      # must not break this stage test with an unrelated ArgumentError.
      Hive::ScreenoteUploader.define_singleton_method(:new) { |*, **| uploader }

      result = Hive::Stages::Artifacts.run!(task, {})

      assert_equal({ commit: "artifacts_collected", status: :complete }, result)
      assert_equal [ "01-home.png" ], uploader.files
    ensure
      Hive::Stages::Artifacts.define_singleton_method(:spawn_artifacts_agent, original_spawn)
      Hive::Config.define_singleton_method(:load_global_screenote, original_load)
      Hive::ScreenoteUploader.define_singleton_method(:new, original_new)
    end
  end

  def test_media_item_path_rejects_traversal_and_nested_names
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      FileUtils.mkdir_p(File.join(task.folder, "media"))

      assert_nil Hive::Stages::Artifacts.media_item_path(task, "../evil.png"),
                 "a ../-shaped filename must not resolve to an upload path"
      assert_nil Hive::Stages::Artifacts.media_item_path(task, "sub/evil.png"),
                 "a nested filename must not resolve to an upload path"
      assert_nil Hive::Stages::Artifacts.media_item_path(task, "")
    end
  end

  def test_media_item_path_refuses_symlink_escapes
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      media_dir = File.join(task.folder, "media")
      FileUtils.mkdir_p(media_dir)
      secret = File.join(dir, "secret.png")
      File.binwrite(secret, "secret")
      File.symlink(secret, File.join(media_dir, "01-home.png"))

      assert_nil Hive::Stages::Artifacts.media_item_path(task, "01-home.png"),
                 "a media symlink escaping the media dir must not resolve to an upload path"
    end
  end

  def test_media_item_path_resolves_a_real_still
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      media_dir = File.join(task.folder, "media")
      FileUtils.mkdir_p(media_dir)
      File.binwrite(File.join(media_dir, "01-home.png"), "png")

      assert_equal File.realpath(File.join(media_dir, "01-home.png")),
                   Hive::Stages::Artifacts.media_item_path(task, "01-home.png")
    end
  end

  def test_media_item_path_refuses_a_media_dir_symlinked_outside_the_task_folder
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      outside = File.join(dir, "outside")
      FileUtils.mkdir_p(outside)
      File.binwrite(File.join(outside, "01-home.png"), "png")
      # media/ itself is a symlink pointing out of the task folder.
      File.symlink(outside, File.join(task.folder, "media"))

      assert_nil Hive::Stages::Artifacts.media_item_path(task, "01-home.png"),
                 "a media dir symlinked outside the task folder must not become a trusted root"
    end
  end

  def test_media_item_path_skips_a_null_byte_filename_without_raising
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      FileUtils.mkdir_p(File.join(task.folder, "media"))

      assert_nil Hive::Stages::Artifacts.media_item_path(task, "a\x00.png"),
                 "a null byte in the agent-written name must skip the one item, not raise"
    end
  end

  def test_upload_eligibility_mirrors_the_web_filename_shape
    base = { "push_to_screenote" => true, "screenote_url" => nil, "type" => "still" }

    assert Hive::Stages::Artifacts.upload_item_to_screenote?(base.merge("file" => "01-home.png"))
    assert Hive::Stages::Artifacts.upload_item_to_screenote?(base.merge("file" => "02-state.jpeg"))
    refute Hive::Stages::Artifacts.upload_item_to_screenote?(base.merge("file" => "my shot.png")),
           "a name with a space can't be displayed by hivebox, so it must not be uploaded"
    refute Hive::Stages::Artifacts.upload_item_to_screenote?(base.merge("file" => "shot\n.png")),
           "a name with a newline must not be uploaded"
    refute Hive::Stages::Artifacts.upload_item_to_screenote?(base.merge("file" => "demo.gif")),
           "screenote hosts PNG/JPEG stills only, never GIFs — even when push_to_screenote is true"
  end

  def test_push_manifest_media_rejects_a_push_flagged_gif
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      media_dir = File.join(task.folder, "media")
      FileUtils.mkdir_p(media_dir)
      File.binwrite(File.join(media_dir, "demo.gif"), "gif")
      write_manifest(task, {
        "schema" => 1,
        "status" => "captured",
        "surface" => "ui",
        "items" => [
          { "file" => "demo.gif", "type" => "gif", "caption" => "Motion", "push_to_screenote" => true, "screenote_url" => nil }
        ]
      })
      uploader = StubUploader.new

      Hive::Stages::Artifacts.push_manifest_media_to_screenote(task, uploader: uploader)

      assert_empty uploader.files,
                   "a push-flagged GIF must be rejected by the filename gate, not uploaded"
    end
  end

  def test_push_manifest_media_skips_items_missing_on_disk
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      FileUtils.mkdir_p(File.join(task.folder, "media"))
      # No 01-home.png written to disk.
      write_manifest(task, {
        "schema" => 1,
        "status" => "captured",
        "surface" => "ui",
        "items" => [
          { "file" => "01-home.png", "type" => "still", "caption" => "Home", "push_to_screenote" => true, "screenote_url" => nil }
        ]
      })
      uploader = StubUploader.new

      Hive::Stages::Artifacts.push_manifest_media_to_screenote(task, uploader: uploader)

      assert_empty uploader.files,
                   "a manifest item naming a png missing on disk must be skipped, not uploaded or crash"
    end
  end

  def test_push_manifest_media_ignores_an_unknown_schema_version
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      media_dir = File.join(task.folder, "media")
      FileUtils.mkdir_p(media_dir)
      File.binwrite(File.join(media_dir, "01-home.png"), "png")
      write_manifest(task, {
        "schema" => 2,
        "status" => "captured",
        "surface" => "ui",
        "items" => [
          { "file" => "01-home.png", "type" => "still", "caption" => "Home", "push_to_screenote" => true, "screenote_url" => nil }
        ]
      })
      uploader = StubUploader.new

      Hive::Stages::Artifacts.push_manifest_media_to_screenote(task, uploader: uploader)

      assert_empty uploader.files,
                   "a future schema version must be skipped, not misread as v1"
    end
  end

  def test_push_manifest_media_stops_uploading_once_the_budget_is_exhausted
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      media_dir = File.join(task.folder, "media")
      FileUtils.mkdir_p(media_dir)
      File.binwrite(File.join(media_dir, "01-home.png"), "png")
      write_manifest(task, {
        "schema" => 1,
        "status" => "captured",
        "surface" => "ui",
        "items" => [
          { "file" => "01-home.png", "type" => "still", "caption" => "Home", "push_to_screenote" => true, "screenote_url" => nil }
        ]
      })
      uploader = StubUploader.new

      # First clock read seeds the deadline; every later read is past it, so the
      # loop must break before starting any upload. Minitest::Mock.stub isn't
      # bundled, so patch the singleton method and restore via ensure.
      calls = 0
      original_clock = Process.singleton_class.instance_method(:clock_gettime)
      Process.define_singleton_method(:clock_gettime) do |*|
        calls += 1
        calls == 1 ? 0.0 : Hive::Stages::Artifacts::SCREENOTE_UPLOAD_BUDGET_SEC + 1000.0
      end

      begin
        _out, err = capture_io do
          Hive::Stages::Artifacts.push_manifest_media_to_screenote(task, uploader: uploader)
        end
      ensure
        Process.singleton_class.define_method(:clock_gettime, original_clock)
      end

      assert_empty uploader.files, "no still may be uploaded once the wall-clock budget is exhausted"
      assert_includes err, "screenote upload budget"
      manifest = JSON.parse(File.read(Hive::Stages::Artifacts.media_manifest_path(task)))
      assert_nil manifest.dig("items", 0, "screenote_url"),
                 "the budget-skipped still keeps a blank screenote_url"
    end
  end

  def test_push_manifest_media_touches_the_task_folder_after_rewrite
    Dir.mktmpdir("hive-artifacts-stage") do |dir|
      task = make_artifacts_task(dir)
      media_dir = File.join(task.folder, "media")
      FileUtils.mkdir_p(media_dir)
      File.binwrite(File.join(media_dir, "01-home.png"), "png")
      write_manifest(task, {
        "schema" => 1,
        "status" => "captured",
        "surface" => "ui",
        "items" => [
          { "file" => "01-home.png", "type" => "still", "caption" => "Home", "push_to_screenote" => true, "screenote_url" => nil }
        ]
      })
      # Backdate the folder so a real touch is observable without sleeping.
      past = Time.now - 3600
      File.utime(past, past, task.folder)
      uploader = StubUploader.new

      Hive::Stages::Artifacts.push_manifest_media_to_screenote(task, uploader: uploader)

      assert_operator File.mtime(task.folder), :>, past + 1,
                      "the task folder mtime must be bumped so the status feed broadcasts the hosted links"
    end
  end

  private

  StubUploader = Struct.new(:nil_result_for, keyword_init: true) do
    def initialize(nil_result_for: nil)
      super
      @files = []
    end

    attr_reader :files

    def upload(path:, title:)
      files << File.basename(path)
      return nil if File.basename(path) == nil_result_for

      { "annotate_url" => "https://screenote.test/#{File.basename(path)}", "screenshot_id" => title }
    end
  end

  def make_artifacts_task(dir)
    folder = File.join(dir, ".hive-state", "stages", "7-artifacts", "demo-260522-aaaa")
    FileUtils.mkdir_p(folder)
    Hive::Task.new(folder)
  end

  def write_manifest(task, manifest)
    media_dir = File.join(task.folder, "media")
    FileUtils.mkdir_p(media_dir)
    File.write(File.join(media_dir, "manifest.json"), "#{JSON.pretty_generate(manifest)}\n")
  end

  def with_stubbed_artifacts_spawn
    original = Hive::Stages::Artifacts.method(:spawn_artifacts_agent)
    spawns = []
    Hive::Stages::Artifacts.define_singleton_method(:spawn_artifacts_agent) do |task, cfg, prompt, profile|
      spawns << { task: task, cfg: cfg, prompt: prompt, profile: profile }
      Hive::Markers.set(task.state_file, :complete)
      { status: :complete }
    end

    { result: yield, spawns: spawns }
  ensure
    Hive::Stages::Artifacts.define_singleton_method(:spawn_artifacts_agent, original)
  end
end
