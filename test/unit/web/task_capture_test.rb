require "test_helper"
require "base64"
require "hive/web/task_capture"

class WebTaskCaptureTest < Minitest::Test
  include HiveTestHelper

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
        platform: RbConfig::CONFIG.fetch("arch"),
        bundler_executable: Gem.bin_path("bundler", "bundle", "= 2.7.2")
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
      assert_equal 2, manifest.fetch("schema_version")
      assert_equal "built_in", manifest.dig("recorder", "kind")
      assert_equal "hivebox", manifest.dig("evidence", "type")
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

  def test_server_readiness_writer_remains_owned_by_the_server_thread
    Dir.mktmpdir("hive-task-capture-server") do |root|
      task_folder = File.join(root, ".hive-state", "stages", "7-artifacts", "demo-task")
      FileUtils.mkdir_p(task_folder)
      factory = lambda do |output:, control_io:, lifecycle_token:, **|
        Object.new.tap do |server|
          server.define_singleton_method(:call) do
            sleep 0.01
            output.puts(JSON.generate(
              "schema" => Hive::Web::CaptureRuntime::SCHEMA,
              "schema_version" => Hive::Web::CaptureRuntime::SCHEMA_VERSION,
              "lifecycle_id" => lifecycle_token,
              "readiness_url" => "http://127.0.0.1:4567/health"
            ))
            output.flush
            control_io.read
          end
        end
      end
      capture = Hive::Web::TaskCapture.new(
        task_folder: task_folder,
        server_factory: factory
      )

      session = capture.send(
        :start_server,
        source_root: root,
        runtime_root: File.join(root, "runtime"),
        lifecycle_token: "capture-ready",
        log_path: File.join(root, "capture-server.log")
      )

      assert_equal "http://127.0.0.1:4567", session.fetch(:base_url)
      capture.send(:stop_server!, session)
      refute session.fetch(:thread).alive?
    ensure
      capture&.send(:stop_server!, session) if session && session.fetch(:thread).alive?
    end
  end

  def test_server_boot_failure_includes_the_isolated_server_log
    Dir.mktmpdir("hive-task-capture-server") do |root|
      task_folder = File.join(root, ".hive-state", "stages", "7-artifacts", "demo-task")
      FileUtils.mkdir_p(task_folder)
      factory = lambda do |output:, error:, **|
        Object.new.tap do |server|
          server.define_singleton_method(:call) do
            error.puts("locked bundle could not boot Rails")
            error.flush
            output.flush
            raise "bootstrap stopped"
          end
        end
      end
      capture = Hive::Web::TaskCapture.new(
        task_folder: task_folder,
        server_factory: factory
      )

      error = assert_raises(Hive::Web::TaskCapture::CaptureError) do
        capture.send(
          :start_server,
          source_root: root,
          runtime_root: File.join(root, "runtime"),
          lifecycle_token: "capture-failed",
          log_path: File.join(root, "capture-server.log")
        )
      end

      assert_match(/bootstrap stopped/, error.message)
      assert_match(/locked bundle could not boot Rails/, error.message)
    end
  end

  def test_call_rejects_missing_or_mismatched_immutable_source_head
    with_capture_task do |root, task_folder, source|
      capture = Hive::Web::TaskCapture.new(task_folder: task_folder)
      capture.define_singleton_method(:capture_requirement) do
        { "result" => "required", "implementation_head" => "" }
      end
      capture.define_singleton_method(:owned_source_root) { source }
      error = assert_raises(Hive::Web::TaskCapture::CaptureError) { capture.call }
      assert_match(/no immutable implementation HEAD/, error.message)

      entry = Struct.new(:source_sha).new("b" * 40)
      capture = Hive::Web::TaskCapture.new(
        task_folder: task_folder, source_bundle: FakeBundle.new(entry, 0)
      )
      capture.define_singleton_method(:capture_requirement) do
        { "result" => "required", "implementation_head" => "a" * 40 }
      end
      capture.define_singleton_method(:owned_source_root) { source }
      error = assert_raises(Hive::Web::TaskCapture::CaptureError) { capture.call }
      assert_match(/does not match requirement/, error.message)
    end
  end

  def test_conventional_project_without_provider_fails_before_hivebox_recorder_construction
    with_capture_task do |root, task_folder, source|
      FileUtils.mkdir_p(File.join(source, "app"))
      File.write(File.join(source, "Gemfile.lock"), "GEM\n")
      run!("git", "-C", source, "init", "-b", "main", "--quiet")
      run!("git", "-C", source, "config", "user.email", "test@example.com")
      run!("git", "-C", source, "config", "user.name", "Test")
      run!("git", "-C", source, "config", "commit.gpgsign", "false")
      run!("git", "-C", source, "add", ".")
      run!("git", "-C", source, "commit", "-m", "fixture", "--quiet")
      head = run!("git", "-C", source, "rev-parse", "HEAD").strip
      capture = Hive::Web::TaskCapture.new(task_folder: task_folder)
      capture.define_singleton_method(:capture_requirement) do
        { "result" => "required", "implementation_head" => head }
      end
      capture.define_singleton_method(:owned_source_root) { source }
      source_bundle_calls = 0
      browser_calls = 0
      server_calls = 0
      source_bundle_constructor = lambda do |**|
        source_bundle_calls += 1
        raise "Hivebox recorder must not be constructed"
      end
      capture.define_singleton_method(:browser_bundle) do |_source_root|
        browser_calls += 1
        raise "browser bundle must not be constructed"
      end
      capture.define_singleton_method(:start_server) do |**|
        server_calls += 1
        raise "server must not start"
      end

      error = with_replaced_singleton_method(
        Hive::Web::SourceBundle, :new, source_bundle_constructor
      ) do
        assert_raises(Hive::Web::TaskCapture::CaptureError) { capture.call }
      end

      assert_equal(
        "no supported artifact capture provider is available for a conventional project root: " \
        "the built-in recorder capability is absent and no project provider is configured. " \
        "Declare artifacts.capture.provider in #{File.join(root, '.hive-state', 'config.yml')} " \
        "with a project-owned recorder command.",
        error.message
      )
      refute_includes error.message, "web/Gemfile"
      refute_includes error.message, "web/Gemfile.lock"
      assert_equal 0, source_bundle_calls
      assert_equal 0, browser_calls
      assert_equal 0, server_calls
      refute File.exist?(File.join(task_folder, "media"))
      assert_equal root, File.dirname(File.dirname(File.dirname(File.dirname(task_folder))))
    end
  end

  def test_non_linux_selection_reports_project_provider_unavailability
    with_capture_task do |_root, task_folder, source|
      File.write(File.join(source, "Gemfile.lock"), "GEM\n")
      original_platform = RUBY_PLATFORM
      original_verbose = $VERBOSE
      $VERBOSE = nil
      Object.send(:remove_const, :RUBY_PLATFORM)
      Object.const_set(:RUBY_PLATFORM, "arm64-darwin26")
      begin
        [
          {},
          {
            "artifacts" => {
              "capture" => {
                "provider" => {
                  "name" => "fixture", "command" => [ "bin/provider" ],
                  "timeout_sec" => 2
                }
              }
            }
          }
        ].each do |project_config|
          capture = Hive::Web::TaskCapture.new(
            task_folder: task_folder,
            project_config: project_config
          )

          error = assert_raises(Hive::Web::TaskCapture::CaptureError) do
            capture.send(:select_recorder, source)
          end

          assert_match(/project-provider capture is unavailable on arm64-darwin26/i,
                       error.message)
          assert_match(/Linux child-subreaper support/, error.message)
          refute_includes error.message, "Declare artifacts.capture.provider"
        end
      ensure
        Object.send(:remove_const, :RUBY_PLATFORM)
        Object.const_set(:RUBY_PLATFORM, original_platform)
        $VERBOSE = original_verbose
      end
    end
  end

  def test_complete_hive_tree_selects_the_built_in_recorder_capability
    with_capture_task do |_root, task_folder, _source|
      hive_root = File.expand_path("../../..", __dir__)
      capture = Hive::Web::TaskCapture.new(task_folder: task_folder)

      assert capture.send(:built_in_recorder_compatible?, hive_root)
      assert_equal :built_in, capture.send(:select_recorder, hive_root).fetch(:kind)
    end
  end

  def test_configured_conventional_provider_publishes_valid_v2_evidence_without_hivebox
    unrelated_child = start_unrelated_caller_child
    with_capture_task do |_root, task_folder, source|
      FileUtils.mkdir_p([ File.join(source, "app"), File.join(source, "bin") ])
      File.write(File.join(source, "Gemfile.lock"), "GEM\n")
      provider_path = File.join(source, "bin", "hive-capture")
      File.write(provider_path, <<~'RUBY')
        #!/usr/bin/env ruby
        require "base64"
        require "digest"
        require "json"

        request = JSON.parse($stdin.read)
        path = File.join(request.fetch("staging_root"), "provider.png")
        File.binwrite(
          path,
          Base64.decode64(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
          )
        )
        puts JSON.generate(
          "schema" => "hive-project-capture-result",
          "schema_version" => 1,
          "status" => "captured",
          "artifacts" => [
            {
              "file" => File.basename(path),
              "bytes" => File.size(path),
              "sha256" => Digest::SHA256.file(path).hexdigest
            }
          ],
          "evidence" => {
            "task" => request.fetch("task"),
            "source_root" => request.fetch("source_root"),
            "source_sha" => request.fetch("source_sha")
          },
          "cleanup" => {
            "port" => "released", "processes" => "clean", "runtime" => "cleaned"
          },
          "diagnostic" => nil
        )
      RUBY
      FileUtils.chmod(0o755, provider_path)
      run!("git", "-C", source, "init", "-b", "main", "--quiet")
      run!("git", "-C", source, "config", "user.email", "test@example.com")
      run!("git", "-C", source, "config", "user.name", "Test")
      run!("git", "-C", source, "config", "commit.gpgsign", "false")
      run!("git", "-C", source, "add", ".")
      run!("git", "-C", source, "commit", "-m", "fixture", "--quiet")
      head = run!("git", "-C", source, "rev-parse", "HEAD").strip
      File.write(
        File.join(File.dirname(File.dirname(File.dirname(task_folder))), "config.yml"),
        {
          "artifacts" => {
            "capture" => {
              "provider" => {
                "name" => "rails",
                "command" => [ "bin/hive-capture" ],
                "timeout_sec" => 10
              }
            }
          }
        }.to_yaml
      )
      capture = nil
      source_bundle_calls = 0
      manifest = with_fake_png_media_tools do
        capture = Hive::Web::TaskCapture.new(task_folder: task_folder)
        capture.define_singleton_method(:capture_requirement) do
          { "result" => "required", "implementation_head" => head }
        end
        capture.define_singleton_method(:owned_source_root) { source }
        with_replaced_singleton_method(
          Hive::Web::SourceBundle, :new,
          lambda do |**|
            source_bundle_calls += 1
            raise "Hivebox recorder must not be constructed"
          end
        ) { capture.call }
      end

      assert_equal 0, source_bundle_calls
      assert_equal 2, manifest.fetch("schema_version")
      assert_equal "project_provider", manifest.dig("recorder", "kind")
      assert_equal "rails", manifest.dig("recorder", "name")
      assert_equal task_folder.split("/").last, manifest.dig("evidence", "details", "task")
      assert_equal File.realpath(source), manifest.dig("evidence", "details", "source_root")
      assert_equal head, manifest.dig("evidence", "details", "source_sha")
      assert_equal 1, manifest.fetch("artifacts").length
      assert_empty Dir.glob(File.join(task_folder, "media", ".capture-*"))

      policy = Hive::Artifacts::CapturePolicy.new(
        task: capture.task,
        project: "demo",
        changed_paths: [ "app/views/demo.html.erb" ],
        task_generation: "provider-generation",
        base_sha: "a" * 40,
        head_sha: head
      )
      policy.ensure!
      assert policy.capture_satisfied?
    end
    assert_unrelated_caller_child_alive(unrelated_child)
  ensure
    stop_unrelated_caller_child(unrelated_child)
  end

  def test_provider_target_mutation_is_detected_before_any_media_is_published
    unrelated_child = start_unrelated_caller_child
    with_capture_task do |_root, task_folder, source|
      FileUtils.mkdir_p([ File.join(source, "app"), File.join(source, "bin") ])
      lockfile = File.join(source, "Gemfile.lock")
      File.write(lockfile, "GEM\n")
      provider_path = File.join(source, "bin", "mutating-capture")
      File.write(provider_path, <<~'RUBY')
        #!/usr/bin/env ruby
        require "digest"
        require "json"

        request = JSON.parse($stdin.read)
        File.open(File.join(request.fetch("source_root"), "Gemfile.lock"), "a") { |file| file.puts("MUTATED") }
        path = File.join(request.fetch("staging_root"), "provider.png")
        File.binwrite(path, "provider")
        puts JSON.generate(
          "schema" => "hive-project-capture-result",
          "schema_version" => 1,
          "status" => "captured",
          "artifacts" => [
            {
              "file" => File.basename(path),
              "bytes" => File.size(path),
              "sha256" => Digest::SHA256.file(path).hexdigest
            }
          ],
          "evidence" => {},
          "cleanup" => {
            "port" => "released", "processes" => "clean", "runtime" => "cleaned"
          },
          "diagnostic" => nil
        )
      RUBY
      FileUtils.chmod(0o755, provider_path)
      run!("git", "-C", source, "init", "-b", "main", "--quiet")
      run!("git", "-C", source, "config", "user.email", "test@example.com")
      run!("git", "-C", source, "config", "user.name", "Test")
      run!("git", "-C", source, "config", "commit.gpgsign", "false")
      run!("git", "-C", source, "add", ".")
      run!("git", "-C", source, "commit", "-m", "fixture", "--quiet")
      head = run!("git", "-C", source, "rev-parse", "HEAD").strip
      capture = Hive::Web::TaskCapture.new(
        task_folder: task_folder,
        project_config: {
          "artifacts" => {
            "capture" => {
              "provider" => {
                "name" => "mutator",
                "command" => [ "bin/mutating-capture" ],
                "timeout_sec" => 10
              }
            }
          }
        }
      )
      capture.define_singleton_method(:capture_requirement) do
        { "result" => "required", "implementation_head" => head }
      end
      capture.define_singleton_method(:owned_source_root) { source }

      error = assert_raises(Hive::Web::TaskCapture::CaptureError) { capture.call }

      assert_match(/cleanliness changed/, error.message)
      media = File.join(task_folder, "media")
      assert File.directory?(media)
      assert_empty Dir.children(media)
      refute File.exist?(File.join(media, "capture-manifest.json"))
    end
    assert_unrelated_caller_child_alive(unrelated_child)
  ensure
    stop_unrelated_caller_child(unrelated_child)
  end

  def test_real_provider_failures_revalidate_source_and_preserve_both_errors
    unrelated_child = start_unrelated_caller_child
    failures = {
      "nonzero" => /failed \(exit 7\)/,
      "timeout" => /timed out after 1s/,
      "malformed-output" => /returned malformed JSON/,
      "overflow" => /stdout exceeded 262144 bytes/
    }
    provider_body = <<~'RUBY'
      #!/usr/bin/env ruby

      mode = ARGV.fetch(0)
      File.open("Gemfile.lock", "a") { |file| file.puts("MUTATED") }
      case mode
      when "nonzero"
        warn "fixture failure"
        exit 7
      when "timeout"
        sleep 5
      when "malformed-output"
        puts "{"
      when "overflow"
        STDOUT.write("x" * (300 * 1024))
      end
    RUBY

    failures.each do |failure, provider_pattern|
      with_capture_task do |_root, task_folder, source|
        head = prepare_conventional_provider_source(source, provider_body: provider_body)
        capture = provider_capture(
          task_folder: task_folder,
          source: source,
          head: head,
          provider: nil,
          command: [ "bin/provider", failure ]
        )

        error = assert_raises(Hive::Web::TaskCapture::CaptureError, failure) { capture.call }

        assert_match provider_pattern, error.message, failure
        assert_match(/source custody also failed.*source.*changed/i, error.message, failure)
        assert_empty Dir.children(File.join(task_folder, "media")), failure
      end
    end
    assert_unrelated_caller_child_alive(unrelated_child)
  ensure
    stop_unrelated_caller_child(unrelated_child)
  end

  def test_provider_ignored_path_mutation_is_detected_before_publication
    with_capture_task do |_root, task_folder, source|
      head = prepare_conventional_provider_source(source, ignored: "tmp/\n")
      provider = Object.new
      provider.define_singleton_method(:call) do |staging_root:, source_root:, **|
        FileUtils.mkdir_p(File.join(source_root, "tmp"))
        File.write(File.join(source_root, "tmp", "ignored.txt"), "mutation")
        path = File.join(staging_root, "proof.png")
        File.binwrite(path, Base64.decode64(WebTaskCaptureTest::PNG_1X1_BASE64))
        Hive::Web::ProjectCaptureProvider::Result.new(
          name: "fixture",
          command: [ "bin/provider" ],
          environment_keys: [ "PATH" ],
          artifacts: [
            {
              "file" => "proof.png",
              "bytes" => File.size(path),
              "sha256" => Digest::SHA256.file(path).hexdigest,
              "source_path" => path
            }
          ],
          evidence: {},
          cleanup: Hive::Web::ProjectCaptureProvider::CLEANUP,
          diagnostic: nil,
          started_at: Time.now.utc,
          finished_at: Time.now.utc
        )
      end
      capture = provider_capture(
        task_folder: task_folder,
        source: source,
        head: head,
        provider: provider
      )

      error = assert_raises(Hive::Web::TaskCapture::CaptureError) { capture.call }

      assert_match(/source.*changed/i, error.message)
      assert File.file?(File.join(source, "tmp", "ignored.txt")),
             "custody detection must not hide or restore the provider mutation"
      assert_empty Dir.children(File.join(task_folder, "media"))
    end
  end

  def test_provider_source_rejects_hidden_index_flags_before_execution
    {
      "assume-unchanged" => "--assume-unchanged",
      "skip-worktree" => "--skip-worktree"
    }.each do |name, flag|
      with_capture_task do |_root, task_folder, source|
        head = prepare_conventional_provider_source(source)
        run!("git", "-C", source, "update-index", flag, "--", "Gemfile.lock")
        File.write(File.join(source, "Gemfile.lock"), "hidden #{name} mutation\n")
        capture = Hive::Web::TaskCapture.new(
          task_folder: task_folder,
          environment: { "PATH" => ENV.fetch("PATH", "") }
        )

        error = assert_raises(Hive::Web::TaskCapture::CaptureError, name) do
          capture.send(
            :verify_provider_source!, source, head,
            provider_executable: "bin/provider"
          )
        end

        assert_match(/non-default Git index flags/i, error.message, name)
      end
    end
  end

  def test_provider_source_requires_the_literal_executable_path_to_be_tracked
    with_capture_task do |_root, task_folder, source|
      prepare_conventional_provider_source(source, ignored: "bin/capture*\n")
      tracked_match = File.join(source, "bin", "capture-safe")
      File.binwrite(tracked_match, "tracked decoy\n")
      run!("git", "-C", source, "add", "-f", "--", "bin/capture-safe")
      run!("git", "-C", source, "commit", "-m", "track decoy", "--quiet")
      head = run!("git", "-C", source, "rev-parse", "HEAD").strip
      write_executable(File.join(source, "bin", "capture*"), "#!/bin/sh\nexit 0\n")
      capture = Hive::Web::TaskCapture.new(
        task_folder: task_folder,
        environment: { "PATH" => ENV.fetch("PATH", "") }
      )

      error = assert_raises(Hive::Web::TaskCapture::CaptureError) do
        capture.send(
          :verify_provider_source!, source, head,
          provider_executable: "bin/capture*"
        )
      end

      assert_match(/Git check failed/i, error.message)
    end
  end

  def test_provider_source_rejects_hidden_index_flags_after_execution
    {
      "assume-unchanged" => "--assume-unchanged",
      "skip-worktree" => "--skip-worktree"
    }.each do |name, flag|
      with_capture_task do |root, task_folder, source|
        head = prepare_conventional_provider_source(source)
        capture = Hive::Web::TaskCapture.new(
          task_folder: task_folder,
          environment: { "PATH" => ENV.fetch("PATH", "") }
        )
        snapshot = capture.send(
          :verify_provider_source!, source, head,
          provider_executable: "bin/provider"
        )
        runner = method(:run!)
        provider = Object.new
        provider.define_singleton_method(:call) do |**|
          runner.call("git", "-C", source, "update-index", flag, "--", "Gemfile.lock")
          :provider_result
        end

        error = assert_raises(Hive::Web::TaskCapture::CaptureError, name) do
          capture.send(
            :call_provider_with_source_custody,
            provider,
            source_root: source,
            expected_head: head,
            provider_executable: "bin/provider",
            source_snapshot: snapshot,
            staging: File.join(root, "staging"),
            runtime_root: File.join(root, "runtime")
          )
        end

        assert_match(/non-default Git index flags/i, error.message, name)
      end
    end
  end

  def test_provider_git_checks_share_one_monotonic_deadline
    with_capture_task do |root, task_folder, source|
      fake_bin = File.join(root, "fake-bin")
      git_path = File.join(fake_bin, "git")
      calls_path = File.join(root, "git-calls.log")
      FileUtils.mkdir_p(fake_bin)
      FileUtils.mkdir_p(File.join(source, "bin"))
      File.binwrite(File.join(source, "bin", "provider"), "provider\n")
      write_executable(git_path, <<~RUBY)
        #!#{RbConfig.ruby}
        File.open(#{calls_path.inspect}, "a") { |file| file.puts(ARGV.join("\\t")) }
        sleep 0.12
        marker = ARGV.index("-C")
        source = ARGV.fetch(marker + 1)
        command = ARGV.drop(marker + 2)
        case command
        when [ "rev-parse", "--show-toplevel" ]
          puts source
        when [ "rev-parse", "HEAD" ]
          puts "#{'a' * 40}"
        when [ "status", "--porcelain=v1", "--untracked-files=all", "--ignore-submodules=none" ]
        when [ "ls-files", "-v", "-f", "-z" ]
          STDOUT.write("H bin/provider\\0")
        else
          puts "bin/provider"
        end
      RUBY
      capture = Hive::Web::TaskCapture.new(
        task_folder: task_folder,
        environment: { "PATH" => fake_bin }
      )
      original_timeout = Hive::Web::TaskCapture::PROVIDER_SOURCE_SNAPSHOT_TIMEOUT_SEC
      original_verbose = $VERBOSE
      $VERBOSE = nil
      Hive::Web::TaskCapture.send(:remove_const, :PROVIDER_SOURCE_SNAPSHOT_TIMEOUT_SEC)
      Hive::Web::TaskCapture.const_set(:PROVIDER_SOURCE_SNAPSHOT_TIMEOUT_SEC, 0.2)
      begin
        error = assert_raises(Hive::Web::TaskCapture::CaptureError) do
          capture.send(
            :verify_provider_source!, source, "a" * 40,
            provider_executable: "bin/provider"
          )
        end

        assert_match(/source custody exceeded the 0.2-second monotonic (?:inventory )?deadline/i,
                     error.message)
        assert_operator File.readlines(calls_path).length, :<, 5
      ensure
        Hive::Web::TaskCapture.send(:remove_const, :PROVIDER_SOURCE_SNAPSHOT_TIMEOUT_SEC)
        Hive::Web::TaskCapture.const_set(
          :PROVIDER_SOURCE_SNAPSHOT_TIMEOUT_SEC, original_timeout
        )
        $VERBOSE = original_verbose
      end
    end
  end

  def test_provider_git_checks_bound_stdout_and_stderr_while_streaming
    with_capture_task do |root, task_folder, source|
      fake_bin = File.join(root, "fake-bin")
      git_path = File.join(fake_bin, "git")
      FileUtils.mkdir_p(fake_bin)
      capture = Hive::Web::TaskCapture.new(
        task_folder: task_folder,
        environment: { "PATH" => fake_bin }
      )

      { "stdout" => "STDOUT", "stderr" => "STDERR" }.each do |stream, constant|
        write_executable(git_path, <<~RUBY)
          #!#{RbConfig.ruby}
          #{constant}.write("x" * (2 * 1024 * 1024))
        RUBY

        error = assert_raises(Hive::Web::TaskCapture::CaptureError, stream) do
          capture.send(:capture_git!, source, "status")
        end

        assert_match(/Git check #{stream} exceeded/i, error.message, stream)
      end
    end
  end

  def test_provider_index_flag_attestation_streams_large_valid_listing
    with_capture_task do |root, task_folder, source|
      fake_bin = File.join(root, "fake-bin")
      git_path = File.join(fake_bin, "git")
      FileUtils.mkdir_p(fake_bin)
      write_executable(git_path, <<~RUBY)
        #!#{RbConfig.ruby}
        70_000.times { |index| STDOUT.write("H f\#{index}\\0") }
      RUBY
      capture = Hive::Web::TaskCapture.new(
        task_folder: task_folder,
        environment: { "PATH" => fake_bin }
      )
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5

      assert_nil capture.send(
        :verify_provider_source_index_flags!, source, deadline: deadline
      )
    end
  end

  def test_provider_git_check_receives_closed_empty_stdin
    with_capture_task do |root, task_folder, source|
      fake_bin = File.join(root, "fake-bin")
      git_path = File.join(fake_bin, "git")
      FileUtils.mkdir_p(fake_bin)
      write_executable(git_path, <<~RUBY)
        #!#{RbConfig.ruby}
        STDOUT.write(STDIN.read.bytesize.to_s)
      RUBY
      capture = Hive::Web::TaskCapture.new(
        task_folder: task_folder,
        environment: { "PATH" => fake_bin }
      )

      assert_equal "0", capture.send(:capture_git!, source, "status")
    end
  end

  def test_provider_git_check_owns_only_its_command_subtree
    with_capture_task do |_root, task_folder, source|
      head = prepare_conventional_provider_source(source)
      capture = Hive::Web::TaskCapture.new(
        task_folder: task_folder,
        environment: { "PATH" => ENV.fetch("PATH", "") }
      )
      unrelated_child = start_unrelated_caller_child

      assert_equal head, capture.send(:capture_git!, source, "rev-parse", "HEAD").strip
      snapshot = capture.send(
        :verify_provider_source!, source, head,
        provider_executable: "bin/provider"
      )
      refute_empty snapshot
      assert_unrelated_caller_child_alive(unrelated_child)
    ensure
      stop_unrelated_caller_child(unrelated_child)
    end
  end

  def test_provider_git_check_terminates_and_reaps_a_setsid_descendant
    with_capture_task do |root, task_folder, source|
      fake_bin = File.join(root, "fake-bin")
      git_path = File.join(fake_bin, "git")
      pid_path = File.join(root, "detached.pid")
      FileUtils.mkdir_p(fake_bin)
      write_executable(git_path, <<~RUBY)
        #!#{RbConfig.ruby}
        child = fork do
          Process.setsid
          STDIN.reopen(File::NULL)
          STDOUT.reopen(File::NULL, "w")
          STDERR.reopen(File::NULL, "w")
          File.binwrite(#{pid_path.dump}, Process.pid.to_s)
          trap("TERM") {}
          sleep 30
        end
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
        until File.file?(#{pid_path.dump})
          abort "detached child did not start" if
            Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          sleep 0.01
        end
        puts "parent complete"
      RUBY
      capture = Hive::Web::TaskCapture.new(
        task_folder: task_folder,
        environment: { "PATH" => fake_bin }
      )
      child_pid = nil

      error = assert_raises(Hive::Web::TaskCapture::CaptureError) do
        capture.send(:capture_git!, source, "status")
      end
      child_pid = Integer(File.binread(pid_path))

      assert_match(/left child processes running/i, error.message)
      refute Hive::ProcessKill.pid_alive?(child_pid),
             "detached Git helper descendant #{child_pid} survived capture_git!"
    ensure
      child_pid ||= Integer(File.binread(pid_path)) if defined?(pid_path) && File.file?(pid_path)
      if child_pid && Hive::ProcessKill.pid_alive?(child_pid)
        Hive::ProcessKill.terminate_process(child_pid, grace_seconds: 0.1)
      end
    end
  end

  def test_sparse_ignored_source_mutation_hits_the_custody_byte_bound_promptly
    with_capture_task do |_root, task_folder, source|
      head = prepare_conventional_provider_source(source, ignored: "tmp/\n")
      sparse_path = File.join(source, "tmp", "sparse.bin")
      provider = Object.new
      provider.define_singleton_method(:call) do |source_root:, **|
        FileUtils.mkdir_p(File.dirname(sparse_path))
        File.open(sparse_path, "wb") do |file|
          file.truncate((1024 * 1024 * 1024) + 1)
        end
        nil
      end
      capture = provider_capture(
        task_folder: task_folder,
        source: source,
        head: head,
        provider: provider
      )
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      error = assert_raises(Hive::Web::TaskCapture::CaptureError) { capture.call }
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_match(/source.*custody.*1073741824-byte.*limit/i, error.message)
      assert_operator elapsed, :<,
                      Hive::Web::TaskCapture::PROVIDER_SOURCE_SNAPSHOT_TIMEOUT_SEC
      assert_equal (1024 * 1024 * 1024) + 1, File.size(sparse_path)
      assert_empty Dir.children(File.join(task_folder, "media"))
    end
  end

  def test_provider_source_snapshot_deadline_fails_with_actionable_custody_error
    with_capture_task do |_root, task_folder, source|
      File.binwrite(File.join(source, "small.txt"), "small")
      capture = Hive::Web::TaskCapture.new(task_folder: task_folder)
      readings = [ 0, Hive::Web::TaskCapture::PROVIDER_SOURCE_SNAPSHOT_TIMEOUT_SEC ]
      capture.define_singleton_method(:provider_custody_monotonic_now) do
        readings.shift || readings.last
      end

      error = assert_raises(Hive::Web::TaskCapture::CaptureError) do
        capture.send(:provider_source_snapshot!, source)
      end

      assert_match(/source custody exceeded the 30-second monotonic inventory deadline/i,
                   error.message)
      assert_match(/reduce the source tree/i, error.message)
    end
  end

  def test_provider_manifest_over_the_producer_budget_is_rejected_before_publication
    with_capture_task do |_root, task_folder, source|
      head = prepare_conventional_provider_source(source)
      provider = Object.new
      provider.define_singleton_method(:call) do |staging_root:, **|
        path = File.join(staging_root, "proof.png")
        File.binwrite(path, Base64.decode64(WebTaskCaptureTest::PNG_1X1_BASE64))
        Hive::Web::ProjectCaptureProvider::Result.new(
          name: "fixture",
          command: [ "bin/provider" ],
          environment_keys: [ "PATH" ],
          artifacts: [
            {
              "file" => "proof.png",
              "bytes" => File.size(path),
              "sha256" => Digest::SHA256.file(path).hexdigest,
              "source_path" => path
            }
          ],
          evidence: { "blob" => "x" * Hive::ARTIFACT_CAPTURE_MANIFEST_PRODUCER_MAX_BYTES },
          cleanup: Hive::Web::ProjectCaptureProvider::CLEANUP,
          diagnostic: nil,
          started_at: Time.now.utc,
          finished_at: Time.now.utc
        )
      end
      capture = provider_capture(
        task_folder: task_folder,
        source: source,
        head: head,
        provider: provider
      )

      error = assert_raises(Hive::Web::TaskCapture::CaptureError) { capture.call }

      assert_match(/manifest.*producer limit.*245760 bytes/i, error.message)
      media = File.join(task_folder, "media")
      refute File.exist?(File.join(media, "capture-manifest.json"))
      assert_empty Dir.children(media)
    end
  end

  def test_manifest_producer_budget_accepts_just_below_and_rejects_just_above
    with_capture_task do |_root, task_folder, _source|
      capture = Hive::Web::TaskCapture.new(task_folder: task_folder)
      limit = Hive::ARTIFACT_CAPTURE_MANIFEST_PRODUCER_MAX_BYTES
      manifest = { "blob" => "" }
      manifest["blob"] = "x" * (limit - 1 - JSON.generate(manifest).bytesize - 1)

      assert_equal limit - 1, JSON.generate(manifest).bytesize + 1
      assert_equal limit - 1, capture.send(:validate_manifest_budget!, manifest)

      manifest["blob"] << "xx"
      error = assert_raises(Hive::Web::TaskCapture::CaptureError) do
        capture.send(:validate_manifest_budget!, manifest)
      end
      assert_match(/producer limit of #{limit} bytes/, error.message)
    end
  end

  def test_provider_recapture_rotates_changed_bytes_and_reuses_identical_bytes_at_the_same_head
    with_capture_task do |_root, task_folder, source|
      head = prepare_conventional_provider_source(source)
      payloads = [
        Base64.decode64(PNG_1X1_BASE64) + "first",
        Base64.decode64(PNG_1X1_BASE64) + "second",
        Base64.decode64(PNG_1X1_BASE64) + "second"
      ]
      provider = Object.new
      provider.define_singleton_method(:call) do |staging_root:, **|
        path = File.join(staging_root, "proof.png")
        File.binwrite(path, payloads.shift)
        Hive::Web::ProjectCaptureProvider::Result.new(
          name: "fixture",
          command: [ "bin/provider" ],
          environment_keys: [ "PATH" ],
          artifacts: [
            {
              "file" => "proof.png",
              "bytes" => File.size(path),
              "sha256" => Digest::SHA256.file(path).hexdigest,
              "source_path" => path
            }
          ],
          evidence: {},
          cleanup: Hive::Web::ProjectCaptureProvider::CLEANUP,
          diagnostic: nil,
          started_at: Time.now.utc,
          finished_at: Time.now.utc
        )
      end
      capture = provider_capture(
        task_folder: task_folder,
        source: source,
        head: head,
        provider: provider
      )

      first = capture.call.fetch("artifacts").fetch(0).fetch("file")
      assert File.file?(File.join(task_folder, "media", first))

      second = capture.call.fetch("artifacts").fetch(0).fetch("file")
      refute_equal first, second
      refute File.exist?(File.join(task_folder, "media", first))
      assert File.file?(File.join(task_folder, "media", second))

      third = capture.call.fetch("artifacts").fetch(0).fetch("file")
      assert_equal second, third
      assert_equal(
        [ "capture-manifest.json", second ].sort,
        Dir.children(File.join(task_folder, "media")).sort
      )
      assert_empty payloads
    end
  end

  def test_provider_recapture_replaces_non_object_retained_manifests
    invalid_manifests = {
      "array" => [],
      "null" => nil,
      "scalar recorder" => {
        "schema" => "hive-artifact-capture",
        "schema_version" => 2,
        "recorder" => "not-an-object",
        "artifacts" => []
      }
    }

    invalid_manifests.each do |shape, retained_manifest|
      with_capture_task do |_root, task_folder, source|
        head = prepare_conventional_provider_source(source)
        provider = Object.new
        provider.define_singleton_method(:call) do |staging_root:, **|
          path = File.join(staging_root, "proof.png")
          File.binwrite(path, Base64.decode64(WebTaskCaptureTest::PNG_1X1_BASE64))
          Hive::Web::ProjectCaptureProvider::Result.new(
            name: "fixture",
            command: [ "bin/provider" ],
            environment_keys: [ "PATH" ],
            artifacts: [
              {
                "file" => "proof.png",
                "bytes" => File.size(path),
                "sha256" => Digest::SHA256.file(path).hexdigest,
                "source_path" => path
              }
            ],
            evidence: {},
            cleanup: Hive::Web::ProjectCaptureProvider::CLEANUP,
            diagnostic: nil,
            started_at: Time.now.utc,
            finished_at: Time.now.utc
          )
        end
        media = File.join(task_folder, "media")
        FileUtils.mkdir_p(media)
        File.binwrite(
          File.join(media, "capture-manifest.json"),
          JSON.generate(retained_manifest)
        )
        capture = provider_capture(
          task_folder: task_folder,
          source: source,
          head: head,
          provider: provider
        )

        manifest = capture.call

        assert_equal 2, manifest.fetch("schema_version"), shape
        assert_equal "project_provider", manifest.dig("recorder", "kind"), shape
        assert_equal 1, manifest.fetch("artifacts").length, shape
      end
    end
  end

  def test_call_rejects_source_drift_before_publication_and_wraps_structural_errors
    with_capture_task do |_root, task_folder, source|
      entry_class = Struct.new(
        :source_sha, :bundle_path, :bundler_executable, :lock_digests, :cache_key,
        keyword_init: true
      )
      correct = entry_class.new(
        source_sha: "a" * 40, bundle_path: "/bundle",
        bundler_executable: "/bundle-executable", lock_digests: {}, cache_key: "key"
      )
      drifted = correct.dup
      drifted.source_sha = "b" * 40
      entries = [ correct, drifted ]
      source_bundle = Object.new
      source_bundle.define_singleton_method(:ensure!) { entries.shift }
      browser_bundle = FakeBundle.new(Struct.new(:cache_key).new("browser"), 0)
      capture = Hive::Web::TaskCapture.new(
        task_folder: task_folder,
        source_bundle: source_bundle,
        browser_bundle: browser_bundle
      )
      capture.define_singleton_method(:capture_requirement) do
        { "result" => "required", "implementation_head" => "a" * 40 }
      end
      capture.define_singleton_method(:owned_source_root) { source }
      capture.define_singleton_method(:start_server) do |**|
        { base_url: "http://127.0.0.1:4567" }
      end
      capture.define_singleton_method(:stop_server!) { |_session| true }
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
          "accessibility_assertions" => [ "heading visible" ]
        }
      end
      capture.define_singleton_method(:validate_media!) { |*| true }

      error = assert_raises(Hive::Web::TaskCapture::CaptureError) { capture.call }
      assert_match(/cleanliness changed/, error.message)

      capture = Hive::Web::TaskCapture.new(task_folder: task_folder)
      capture.define_singleton_method(:capture_requirement) do
        raise JSON::ParserError, "broken requirement"
      end
      error = assert_raises(Hive::Web::TaskCapture::CaptureError) { capture.call }
      assert_match(/broken requirement/, error.message)
    end
  end

  def test_capture_requirement_uses_the_task_project_name
    with_capture_task do |root, task_folder, _source|
      requirement = { "result" => "required", "implementation_head" => "a" * 40 }
      policy = Struct.new(:requirement) { def ensure! = requirement }.new(requirement)
      calls = []
      replacement = lambda do |_task, project:, **|
        calls << project
        policy
      end
      capture = Hive::Web::TaskCapture.new(task_folder: task_folder)

      result = with_replaced_singleton_method(
        Hive::Artifacts::CapturePolicy, :for_task, replacement
      ) { capture.send(:capture_requirement) }

      assert_equal requirement, result
      assert_equal [ File.basename(root) ], calls
    end
  end

  def test_owned_source_root_enforces_pointer_and_override_identity
    with_capture_task do |_root, task_folder, source|
      other = File.join(File.dirname(source), "other")
      FileUtils.mkdir_p(other)
      pointer = ->(*) { { "path" => source } }
      capture = Hive::Web::TaskCapture.new(
        task_folder: task_folder, source_root: source
      )

      resolved = with_replaced_singleton_method(
        Hive::Worktree, :read_owned_pointer, pointer
      ) { capture.send(:owned_source_root) }
      assert_equal File.realpath(source), resolved

      capture = Hive::Web::TaskCapture.new(
        task_folder: task_folder, source_root: other
      )
      error = with_replaced_singleton_method(
        Hive::Worktree, :read_owned_pointer, pointer
      ) do
        assert_raises(Hive::Web::TaskCapture::CaptureError) do
          capture.send(:owned_source_root)
        end
      end
      assert_match(/does not match/, error.message)

      error = with_replaced_singleton_method(
        Hive::Worktree, :read_owned_pointer,
        ->(*) { raise Hive::WorktreeError, "pointer missing" }
      ) do
        assert_raises(Hive::Web::TaskCapture::CaptureError) do
          capture.send(:owned_source_root)
        end
      end
      assert_match(/worktree is unavailable/, error.message)
    end
  end

  def test_default_server_factory_and_readiness_receipt_validation
    with_capture_task do |root, task_folder, source|
      factory_calls = []
      factory = lambda do |output:, control_io:, lifecycle_token:, **options|
        factory_calls << options
        Object.new.tap do |server|
          server.define_singleton_method(:call) do
            output.puts(JSON.generate(
              "schema" => Hive::Web::CaptureRuntime::SCHEMA,
              "schema_version" => Hive::Web::CaptureRuntime::SCHEMA_VERSION,
              "lifecycle_id" => lifecycle_token,
              "readiness_url" => "http://127.0.0.1:4568/health"
            ))
            output.flush
            control_io.read
          end
        end
      end
      capture = Hive::Web::TaskCapture.new(task_folder: task_folder)

      session = with_replaced_singleton_method(
        Hive::Commands::Web::CaptureServer, :new, factory
      ) do
        capture.send(
          :start_server,
          source_root: source,
          runtime_root: File.join(root, "runtime"),
          lifecycle_token: "capture-default",
          log_path: File.join(root, "capture-server.log")
        )
      end

      assert_equal "http://127.0.0.1:4568", session.fetch(:base_url)
      assert_equal source, factory_calls.first.fetch(:source_root)
      capture.send(:stop_server!, session)
    end
  end

  def test_server_without_receipt_and_invalid_receipt_are_rejected
    with_capture_task do |root, task_folder, source|
      silent = lambda do |**|
        Object.new.tap { |server| server.define_singleton_method(:call) { true } }
      end
      capture = Hive::Web::TaskCapture.new(
        task_folder: task_folder, server_factory: silent
      )
      error = assert_raises(Hive::Web::TaskCapture::CaptureError) do
        capture.send(
          :start_server,
          source_root: source, runtime_root: File.join(root, "runtime-1"),
          lifecycle_token: "capture-silent",
          log_path: File.join(root, "silent.log")
        )
      end
      assert_match(/without a readiness receipt/, error.message)

      invalid = lambda do |output:, **|
        Object.new.tap do |server|
          server.define_singleton_method(:call) do
            output.puts("{}")
            output.flush
          end
        end
      end
      capture = Hive::Web::TaskCapture.new(
        task_folder: task_folder, server_factory: invalid
      )
      error = assert_raises(Hive::Web::TaskCapture::CaptureError) do
        capture.send(
          :start_server,
          source_root: source, runtime_root: File.join(root, "runtime-2"),
          lifecycle_token: "capture-invalid",
          log_path: File.join(root, "invalid.log")
        )
      end
      assert_match(/invalid ownership receipt/, error.message)
    end
  end

  def test_stop_server_tolerates_an_io_that_closes_concurrently
    with_capture_task do |_root, task_folder, _source|
      bad_io = Object.new
      bad_io.define_singleton_method(:closed?) { false }
      bad_io.define_singleton_method(:close) { raise IOError, "already closed" }
      thread = Thread.new { true }
      session = {
        thread: thread,
        control_writer: StringIO.new,
        control_reader: bad_io,
        readiness_reader: StringIO.new,
        log: StringIO.new,
        server_errors: []
      }
      capture = Hive::Web::TaskCapture.new(task_folder: task_folder)

      assert_nil capture.send(:stop_server!, session)
    ensure
      thread&.join
    end
  end

  def test_seed_fixture_uses_locked_cli_and_creates_a_deterministic_task
    with_capture_task do |root, task_folder, source|
      runtime_root = File.join(root, "runtime")
      entry = Struct.new(:bundle_path, :bundler_executable).new(
        "/locked/gems", "/locked/bundle"
      )
      calls = []
      capture = Hive::Web::TaskCapture.new(
        task_folder: task_folder,
        environment: { "PATH" => "/usr/bin:/bin", "GH_TOKEN" => "secret" }
      )
      capture.define_singleton_method(:run_command!) do |argv, env: nil, chdir: nil, **|
        calls << [ argv, env, chdir ]
        if argv.include?("new")
          folder = File.join(
            runtime_root, "fixture", "hive-capture-fixture",
            ".hive-state", "stages", "1-inbox", "synthetic-browser-capture-task"
          )
          FileUtils.mkdir_p(folder)
        end
        true
      end

      seed = capture.send(
        :seed_fixture!,
        source_root: source, runtime_root: runtime_root, source_entry: entry
      )

      assert_equal "hive-capture-fixture", seed.fetch("project")
      assert_equal "synthetic-browser-capture-task", seed.fetch("task")
      hive_calls = calls.select { |argv,| argv.include?("/locked/bundle") }
      assert_equal 2, hive_calls.length
      assert hive_calls.all? { |argv,| argv.take(3) == [ RbConfig.ruby, "/locked/bundle", "exec" ] }
      refute hive_calls.first.fetch(1).key?("GH_TOKEN")
    end
  end

  def test_isolated_cli_environment_keeps_only_safe_ambient_values
    with_capture_task do |root, task_folder, source|
      capture = Hive::Web::TaskCapture.new(
        task_folder: task_folder,
        environment: { "PATH" => "/bin", "LANG" => "C", "GH_TOKEN" => "secret" }
      )
      env = capture.send(
        :isolated_cli_environment,
        File.join(root, "runtime"), File.join(root, "hive-home"), source, "/bundle"
      )

      assert_equal "/bin", env.fetch("PATH")
      assert_equal "C", env.fetch("LANG")
      assert_equal "/bundle", env.fetch("BUNDLE_PATH")
      refute env.key?("GH_TOKEN")
      assert_nil env.fetch("GEM_HOME")
    end
  end

  def test_browser_recording_is_pinned_and_confined_to_staging
    with_capture_task do |root, task_folder, source|
      script = File.join(source, "web", "script", "capture_task_page.cjs")
      FileUtils.mkdir_p(File.dirname(script))
      File.write(script, "// fixture")
      video_directory = File.join(root, "video")
      FileUtils.mkdir_p(video_directory)
      video = File.join(video_directory, "capture.webm")
      File.write(video, "video")
      entry = Struct.new(:browsers_path, :node_modules_path).new(
        "/browsers", "/node-modules"
      )
      capture = Hive::Web::TaskCapture.new(task_folder: task_folder)
      calls = []
      capture.define_singleton_method(:run_command!) do |argv, env:, chdir:, capture:|
        calls << [ argv, env, chdir, capture ]
        [ JSON.generate(
          "video_path" => video,
          "accessibility_assertions" => [ "heading visible" ]
        ), "" ]
      end

      result = capture.send(
        :record_browser!,
        source_root: source, browser_entry: entry,
        runtime_root: File.join(root, "runtime"),
        base_url: "http://127.0.0.1:4567",
        screenshot: File.join(root, "capture.png"),
        video_directory: video_directory
      )

      assert_equal File.realpath(video), result.fetch("video_path")
      assert_equal "node", calls.first.first.first
      assert_equal "/browsers", calls.first.fetch(1).fetch("PLAYWRIGHT_BROWSERS_PATH")
      assert_equal(
        File.join("/node-modules", "playwright"),
        calls.first.fetch(1).fetch("HIVE_PLAYWRIGHT_MODULE")
      )
    end
  end

  def test_browser_recording_rejects_missing_script_outside_media_and_invalid_json
    with_capture_task do |root, task_folder, source|
      capture = Hive::Web::TaskCapture.new(task_folder: task_folder)
      entry = Struct.new(:browsers_path, :node_modules_path).new("/browsers", "/modules")
      args = {
        source_root: source, browser_entry: entry,
        runtime_root: File.join(root, "runtime"),
        base_url: "http://127.0.0.1:4567",
        screenshot: File.join(root, "capture.png"),
        video_directory: File.join(root, "video")
      }
      error = assert_raises(Hive::Web::TaskCapture::CaptureError) do
        capture.send(:record_browser!, **args)
      end
      assert_match(/capture script is missing/, error.message)

      script = File.join(source, "web", "script", "capture_task_page.cjs")
      FileUtils.mkdir_p(File.dirname(script))
      File.write(script, "// fixture")
      FileUtils.mkdir_p(args.fetch(:video_directory))
      outside = File.join(root, "outside.webm")
      File.write(outside, "video")
      capture.define_singleton_method(:run_command!) do |*|
        [ JSON.generate("video_path" => outside), "" ]
      end
      error = assert_raises(Hive::Web::TaskCapture::CaptureError) do
        capture.send(:record_browser!, **args)
      end
      assert_match(/outside its staging root/, error.message)

      capture.define_singleton_method(:run_command!) { |*| [ "{", "" ] }
      error = assert_raises(Hive::Web::TaskCapture::CaptureError) do
        capture.send(:record_browser!, **args)
      end
      assert_match(/invalid evidence/, error.message)
    end
  end

  def test_media_validation_checks_png_video_toolchain_and_duration
    with_capture_task do |root, task_folder, _source|
      capture = Hive::Web::TaskCapture.new(task_folder: task_folder)
      screenshot = File.join(root, "capture.png")
      video = File.join(root, "capture.webm")
      File.write(screenshot, "not png")
      File.write(video, "video")
      error = assert_raises(Hive::Web::TaskCapture::CaptureError) do
        capture.send(:validate_media!, screenshot, video)
      end
      assert_match(/valid PNG/, error.message)

      File.binwrite(screenshot, Hive::Web::TaskCapture::PNG_SIGNATURE + "image")
      FileUtils.rm_f(video)
      error = assert_raises(Hive::Web::TaskCapture::CaptureError) do
        capture.send(:validate_media!, screenshot, video)
      end
      assert_match(/non-empty video/, error.message)
      File.write(video, "video")

      error = with_replaced_singleton_method(
        Hive::InvokedBinary, :which, ->(_name) { nil }
      ) do
        assert_raises(Hive::Web::TaskCapture::CaptureError) do
          capture.send(:validate_media!, screenshot, video)
        end
      end
      assert_match(/ffmpeg is required/, error.message)

      error = with_replaced_singleton_method(
        Hive::InvokedBinary, :which,
        ->(name) { name == "ffmpeg" ? "/bin/true" : nil }
      ) do
        assert_raises(Hive::Web::TaskCapture::CaptureError) do
          capture.send(:validate_media!, screenshot, video)
        end
      end
      assert_match(/ffprobe is required/, error.message)

      capture.define_singleton_method(:run_command!) do |argv, **|
        argv.include?("-show_entries") ? [ "1.25\n", "" ] : [ "", "" ]
      end
      with_replaced_singleton_method(
        Hive::InvokedBinary, :which, ->(name) { "/bin/#{name}" }
      ) do
        assert_nil capture.send(:validate_media!, screenshot, video)
      end

      capture.define_singleton_method(:run_command!) do |argv, **|
        argv.include?("-show_entries") ? [ "0\n", "" ] : [ "", "" ]
      end
      error = with_replaced_singleton_method(
        Hive::InvokedBinary, :which, ->(name) { "/bin/#{name}" }
      ) do
        assert_raises(Hive::Web::TaskCapture::CaptureError) do
          capture.send(:validate_media!, screenshot, video)
        end
      end
      assert_match(/not playable/, error.message)
    end
  end

  def test_secret_manifest_and_command_failures_are_rejected_and_redacted
    with_capture_task do |_root, task_folder, _source|
      capture = Hive::Web::TaskCapture.new(
        task_folder: task_folder, environment: { "PATH" => ENV.fetch("PATH", "") }
      )
      error = assert_raises(Hive::Web::TaskCapture::CaptureError) do
        capture.send(
          :reject_manifest_secrets!,
          { "diagnostic" => "ghp_abcdefghijklmnopqrstuvwxyz1234567890" }
        )
      end
      assert_match(/secret-shaped content/, error.message)

      assert capture.send(
        :run_command!, [ RbConfig.ruby, "-e", "exit 0" ]
      )
      output, = capture.send(
        :run_command!, [ RbConfig.ruby, "-e", "print 'captured'" ], capture: true
      )
      assert_equal "captured", output

      error = assert_raises(Hive::Web::TaskCapture::CaptureError) do
        capture.send(
          :run_command!,
          [
            RbConfig.ruby, "-e",
            "STDERR.write('ghp_abcdefghijklmnopqrstuvwxyz1234567890'); exit 4"
          ]
        )
      end
      refute_includes error.message, "ghp_"
      assert_match(/ruby.*failed/, error.message)

      error = assert_raises(Hive::Web::TaskCapture::CaptureError) do
        capture.send(:run_command!, [ "/definitely/missing/capture-tool" ])
      end
      assert_match(/dependency is unavailable/, error.message)
    end
  end

  def test_capture_server_diagnostic_falls_back_when_log_cannot_be_read
    with_capture_task do |_root, task_folder, _source|
      capture = Hive::Web::TaskCapture.new(task_folder: task_folder)
      log = Object.new
      log.define_singleton_method(:flush) { raise IOError, "closed" }
      error = RuntimeError.new("bootstrap ghp_abcdefghijklmnopqrstuvwxyz1234567890")

      diagnostic = capture.send(
        :capture_server_diagnostic, error, log, "/missing/log"
      )

      refute_includes diagnostic, "ghp_"
      assert_match(/bootstrap/, diagnostic)
    end
  end

  private

  PNG_1X1_BASE64 =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=".freeze

  def write_executable(path, body)
    File.binwrite(path, body)
    FileUtils.chmod(0o755, path)
  end

  def start_unrelated_caller_child
    pid = fork { sleep 60 }
    start_time = Hive::ProcessKill.process_start_time(pid)
    raise "unrelated caller child identity is unavailable" if start_time.to_s.empty?

    { pid: pid, start_time: start_time }
  rescue StandardError
    stop_unrelated_caller_child(pid: pid, start_time: start_time) if pid
    raise
  end

  def assert_unrelated_caller_child_alive(target)
    pid = target.fetch(:pid)
    assert_nil Process.waitpid(pid, Process::WNOHANG),
               "unrelated caller child #{pid} exited during command custody"
    assert Hive::ProcessKill.captured_process_alive?(target),
           "unrelated caller child #{pid} lost its recorded identity during command custody"
  rescue Errno::ECHILD
    flunk "command custody reaped unrelated caller child #{pid}"
  end

  def stop_unrelated_caller_child(target)
    return unless target

    pid = target.fetch(:pid)
    return if Process.waitpid(pid, Process::WNOHANG)

    begin
      Process.kill("TERM", pid)
    rescue Errno::ESRCH
      nil
    end
    Process.wait(pid)
  rescue Errno::ECHILD
    nil
  end

  def prepare_conventional_provider_source(source, ignored: nil,
                                           provider_body: "#!/usr/bin/env ruby\n")
    FileUtils.mkdir_p(File.join(source, "bin"))
    File.write(File.join(source, "Gemfile.lock"), "GEM\n")
    File.write(File.join(source, ".gitignore"), ignored) if ignored
    provider_path = File.join(source, "bin", "provider")
    File.write(provider_path, provider_body)
    FileUtils.chmod(0o755, provider_path)
    run!("git", "-C", source, "init", "-b", "main", "--quiet")
    run!("git", "-C", source, "config", "user.email", "test@example.com")
    run!("git", "-C", source, "config", "user.name", "Test")
    run!("git", "-C", source, "config", "commit.gpgsign", "false")
    run!("git", "-C", source, "add", ".")
    run!("git", "-C", source, "commit", "-m", "fixture", "--quiet")
    run!("git", "-C", source, "rev-parse", "HEAD").strip
  end

  def provider_capture(task_folder:, source:, head:, provider:, command: [ "bin/provider" ])
    options = {
      task_folder: task_folder,
      project_config: {
        "artifacts" => {
          "capture" => {
            "provider" => {
              "name" => "fixture",
              "command" => command,
              "timeout_sec" => 1
            }
          }
        }
      }
    }
    options[:provider_factory] = ->(**) { provider } if provider
    Hive::Web::TaskCapture.new(**options).tap do |capture|
      capture.define_singleton_method(:capture_requirement) do
        { "result" => "required", "implementation_head" => head }
      end
      capture.define_singleton_method(:owned_source_root) { source }
    end
  end

  def with_capture_task
    Dir.mktmpdir("hive-task-capture") do |root|
      source = File.join(root, "source")
      task_folder = File.join(
        root, ".hive-state", "stages", "7-artifacts", "demo-task"
      )
      FileUtils.mkdir_p([ source, task_folder ])
      yield root, task_folder, source
    end
  end
end
