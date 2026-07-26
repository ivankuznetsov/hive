require "digest"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "securerandom"
require "stringio"
require "timeout"
require "tmpdir"
require "uri"
require "hive"
require "hive/artifacts/capture_policy"
require "hive/commands/web/capture_server"
require "hive/invoked_binary"
require "hive/secret_patterns"
require "hive/task"
require "hive/web/browser_bundle"
require "hive/web/capture_runtime"
require "hive/web/source_bundle"
require "hive/worktree"

module Hive
  module Web
    # Captures a deterministic, credential-free Hive UI fixture from the exact
    # clean worktree bound to one artifacts-stage task. Media is staged
    # privately, the source is revalidated after teardown, and the success
    # manifest is published last.
    class TaskCapture
      START_TIMEOUT_SEC = 600
      COMMAND_TIMEOUT_SEC = 120
      DIAGNOSTIC_MAX_BYTES = 16 * 1024
      PNG_SIGNATURE = "\x89PNG\r\n\x1a\n".b.freeze

      class CaptureError < Hive::Error; end

      attr_reader :task

      def initialize(task_folder:, source_root: nil, output: $stdout,
                     error: $stderr, environment: ENV,
                     source_bundle: nil, browser_bundle: nil,
                     runtime_factory: nil, server_factory: nil)
        @task = Hive::Task.new(File.expand_path(task_folder))
        @source_root_override = source_root && File.expand_path(source_root)
        @output = output
        @error = error
        @environment = environment.to_h
        @source_bundle = source_bundle
        @browser_bundle = browser_bundle
        @runtime_factory = runtime_factory
        @server_factory = server_factory
      end

      def call
        requirement = capture_requirement
        raise CaptureError, "capture is not required for this task generation" unless
          requirement.fetch("result") == "required"

        source_root = owned_source_root
        expected_head = requirement.fetch("implementation_head").to_s
        unless expected_head.match?(/\A[0-9a-f]{40,64}\z/)
          raise CaptureError, "capture requirement has no immutable implementation HEAD"
        end
        source_entry = source_bundle(source_root).ensure!
        unless source_entry.source_sha == expected_head
          raise CaptureError,
                "capture source HEAD #{source_entry.source_sha} does not match requirement #{expected_head}"
        end
        browser_entry = browser_bundle(source_root).ensure!
        media_root = validated_media_root
        staging = Dir.mktmpdir(".capture-", media_root)
        runtime_root = Dir.mktmpdir("hive-web-capture-")
        lifecycle_token = "task-capture-#{SecureRandom.hex(12)}"
        started_at = Time.now.utc
        server_log = File.join(staging, "capture-server.log")
        session = start_server(
          source_root: source_root,
          runtime_root: runtime_root,
          lifecycle_token: lifecycle_token,
          log_path: server_log
        )
        seed = seed_fixture!(
          source_root: source_root,
          runtime_root: runtime_root,
          source_entry: source_entry
        )
        screenshot = File.join(staging, "capture.png")
        video_staging = File.join(staging, "video")
        browser_result = record_browser!(
          source_root: source_root,
          browser_entry: browser_entry,
          runtime_root: runtime_root,
          base_url: session.fetch(:base_url),
          screenshot: screenshot,
          video_directory: video_staging
        )
        video = browser_result.fetch("video_path")
        validate_media!(screenshot, video)
        begin
          stop_server!(session)
        ensure
          session = nil
        end

        verified = source_bundle(source_root).ensure!
        unless verified.source_sha == expected_head
          raise CaptureError, "source HEAD or cleanliness changed before capture publication"
        end
        final_paths = publish_media!(
          staging: staging,
          media_root: media_root,
          source_sha: expected_head,
          screenshot: screenshot,
          video: video
        )
        runtime = capture_runtime(
          source_root: source_root,
          runtime_root: runtime_root,
          lifecycle_token: lifecycle_token
        )
        manifest = runtime.capture_manifest(
          task: task.slug,
          source_sha: expected_head,
          lock_digests: source_entry.lock_digests,
          cache_key: source_entry.cache_key,
          command: [
            "hive", "web", "capture", "--task-folder", task.folder,
            "--source-root", source_root
          ],
          fixture_ids: [ seed.fetch("project"), seed.fetch("task") ],
          media_paths: final_paths,
          status: "captured",
          cleanup: {
            "processes" => "clean",
            "port" => "released",
            "runtime" => "cleaned"
          },
          accessibility_assertions: browser_result.fetch("accessibility_assertions"),
          started_at: started_at,
          finished_at: Time.now.utc
        )
        reject_manifest_secrets!(manifest)
        runtime.publish_manifest!(task_folder: task.folder, manifest: manifest)
        manifest
      rescue KeyError, JSON::ParserError, Timeout::Error, SystemCallError => e
        raise CaptureError, bounded_diagnostic(e)
      ensure
        stop_server!(session) if session
        FileUtils.rm_rf(staging) if staging && File.exist?(staging)
        FileUtils.rm_rf(runtime_root) if runtime_root && File.exist?(runtime_root)
      end

      private

      def capture_requirement
        Hive::Artifacts::CapturePolicy.for_task(
          task,
          project: File.basename(task.project_root)
        ).ensure!
      end

      def owned_source_root
        pointer = Hive::Worktree.read_owned_pointer(
          task.folder,
          project_root: task.project_root,
          slug: task.slug,
          expected_root: Hive::Worktree.canonical_root(task.project_root)
        )
        resolved = File.realpath(pointer.fetch("path"))
        if @source_root_override &&
           File.realpath(@source_root_override) != resolved
          raise CaptureError, "--source-root does not match the task-owned worktree"
        end
        resolved
      rescue Hive::WorktreeError, Errno::ENOENT => e
        raise CaptureError, "task-owned capture worktree is unavailable: #{e.message}"
      end

      def source_bundle(source_root)
        @source_bundle ||= Hive::Web::SourceBundle.new(
          source_root: source_root,
          environment: @environment
        )
      end

      def browser_bundle(source_root)
        @browser_bundle ||= Hive::Web::BrowserBundle.new(
          source_root: source_root,
          environment: @environment
        )
      end

      def validated_media_root
        folder = File.realpath(task.folder)
        media = File.join(folder, "media")
        FileUtils.mkdir_p(media, mode: 0o700)
        stat = File.lstat(media)
        raise CaptureError, "task media root must not be a symlink" if stat.symlink?
        raise CaptureError, "task media root has foreign ownership" unless stat.uid == Process.uid
        raise CaptureError, "task media root is not a directory" unless stat.directory?

        FileUtils.chmod(0o700, media)
        File.realpath(media)
      end

      def start_server(source_root:, runtime_root:, lifecycle_token:, log_path:)
        control_reader, control_writer = IO.pipe
        readiness_reader, readiness_writer = IO.pipe
        log = File.open(log_path, File::WRONLY | File::CREAT | File::EXCL, 0o600)
        server = if @server_factory
          @server_factory.call(
            source_root: source_root,
            runtime_root: runtime_root,
            lifecycle_token: lifecycle_token,
            control_io: control_reader,
            output: readiness_writer,
            error: log,
            environment: @environment
          )
        else
          Hive::Commands::Web::CaptureServer.new(
            source_root: source_root,
            runtime_root: runtime_root,
            lifecycle_token: lifecycle_token,
            control_io: control_reader,
            output: readiness_writer,
            error: log,
            environment: @environment
          )
        end
        thread = Thread.new { server.call }
        readiness_writer.close
        line = Timeout.timeout(START_TIMEOUT_SEC) { readiness_reader.gets }
        unless line
          thread.value
          raise CaptureError, "capture server exited without a readiness receipt"
        end
        receipt = JSON.parse(line)
        validate_readiness!(receipt, lifecycle_token)
        {
          thread: thread,
          control_writer: control_writer,
          control_reader: control_reader,
          readiness_reader: readiness_reader,
          log: log,
          base_url: URI(receipt.fetch("readiness_url")).then do |uri|
            "http://127.0.0.1:#{uri.port}"
          end
        }
      rescue StandardError
        control_writer&.close
        control_reader&.close
        readiness_reader&.close
        readiness_writer&.close
        log&.close
        thread&.kill
        thread&.join
        raise
      end

      def validate_readiness!(receipt, lifecycle_token)
        unless receipt["schema"] == Hive::Web::CaptureRuntime::SCHEMA &&
               receipt["schema_version"] == Hive::Web::CaptureRuntime::SCHEMA_VERSION &&
               receipt["lifecycle_id"] == lifecycle_token &&
               receipt["readiness_url"].to_s.match?(%r{\Ahttp://127\.0\.0\.1:\d+/health\z})
          raise CaptureError, "capture server returned an invalid ownership receipt"
        end
      end

      def stop_server!(session)
        session.fetch(:control_writer).close unless session.fetch(:control_writer).closed?
        Timeout.timeout(Hive::Web::CaptureRuntime::CLEANUP_TIMEOUT_SEC + 15) do
          session.fetch(:thread).value
        end
      ensure
        %i[control_writer control_reader readiness_reader log].each do |key|
          io = session[key]
          io&.close unless io&.closed?
        rescue IOError
          nil
        end
      end

      def seed_fixture!(source_root:, runtime_root:, source_entry:)
        project_name = "hive-capture-fixture"
        project_root = File.join(runtime_root, "fixture", project_name)
        FileUtils.mkdir_p(project_root, mode: 0o700)
        run_command!(%w[git init -b main --quiet], chdir: project_root)
        run_command!(%w[git config user.email capture@hive.local], chdir: project_root)
        run_command!(%w[git config user.name Hive Capture], chdir: project_root)
        File.write(File.join(project_root, "README.md"), "# Synthetic capture fixture\n")
        run_command!(%w[git add README.md], chdir: project_root)
        run_command!(%w[git commit -m fixture --quiet], chdir: project_root)
        hive_home = File.join(runtime_root, "hive-home")
        cli_env = isolated_cli_environment(
          runtime_root, hive_home, source_root, source_entry.bundle_path
        )
        hive = [
          "bundle", "exec", RbConfig.ruby, "-I#{File.join(source_root, 'lib')}",
          File.join(source_root, "bin", "hive")
        ]
        run_command!([ *hive, "init", project_root ], env: cli_env, chdir: source_root)
        run_command!(
          [ *hive, "new", project_name, "Synthetic browser capture task" ],
          env: cli_env,
          chdir: source_root
        )
        slug = Dir[File.join(project_root, ".hive-state", "stages", "1-inbox", "*")]
               .map { |path| File.basename(path) }
               .find { |name| name.match?(/\A[a-z][a-z0-9-]+\z/) }
        raise CaptureError, "synthetic capture fixture task was not created" unless slug

        { "project" => project_name, "task" => slug }
      end

      def isolated_cli_environment(runtime_root, hive_home, source_root, bundle_path)
        safe = %w[PATH LANG LC_ALL LC_CTYPE TZ SSL_CERT_FILE SSL_CERT_DIR].to_h do |key|
          [ key, @environment[key] ]
        end.compact
        home = File.join(runtime_root, "fixture-home")
        safe.merge(
          "HOME" => home,
          "XDG_CONFIG_HOME" => File.join(home, ".config"),
          "XDG_CACHE_HOME" => File.join(home, ".cache"),
          "XDG_DATA_HOME" => File.join(home, ".local", "share"),
          "XDG_STATE_HOME" => File.join(home, ".local", "state"),
          "HIVE_HOME" => hive_home,
          "HIVE_CLI_ROOT" => source_root,
          "RUBYOPT" => nil,
          "RUBYLIB" => nil,
          "BUNDLE_GEMFILE" => File.join(source_root, "web", "Gemfile"),
          "BUNDLE_PATH" => bundle_path,
          "BUNDLE_FROZEN" => "1",
          "BUNDLE_DEPLOYMENT" => "1",
          "BUNDLE_DISABLE_SHARED_GEMS" => "1",
          "BUNDLE_APP_CONFIG" => File.join(runtime_root, "fixture-bundle-config"),
          "BUNDLE_USER_HOME" => File.join(home, ".bundle"),
          "GEM_HOME" => nil,
          "GEM_PATH" => nil
        )
      end

      def record_browser!(source_root:, browser_entry:, runtime_root:, base_url:,
                          screenshot:, video_directory:)
        script = File.join(source_root, "web", "script", "capture_task_page.cjs")
        raise CaptureError, "pinned capture script is missing" unless File.file?(script)

        browser_home = File.join(runtime_root, "browser-home")
        FileUtils.mkdir_p(browser_home, mode: 0o700)
        env = {
          "PATH" => @environment.fetch("PATH", "/usr/local/bin:/usr/bin:/bin"),
          "LANG" => @environment["LANG"],
          "LC_ALL" => @environment["LC_ALL"],
          "LC_CTYPE" => @environment["LC_CTYPE"],
          "HOME" => browser_home,
          "XDG_CONFIG_HOME" => File.join(browser_home, ".config"),
          "XDG_CACHE_HOME" => File.join(browser_home, ".cache"),
          "PLAYWRIGHT_BROWSERS_PATH" => browser_entry.browsers_path,
          "HIVE_PLAYWRIGHT_MODULE" => File.join(
            browser_entry.node_modules_path, "playwright"
          ),
          "NODE_OPTIONS" => nil,
          "NODE_PATH" => nil
        }.compact
        output, = run_command!(
          [ "node", script, base_url, screenshot, video_directory ],
          env: env,
          chdir: File.join(source_root, "web"),
          capture: true
        )
        result = JSON.parse(output)
        result["video_path"] = File.realpath(result.fetch("video_path"))
        unless result["video_path"].start_with?("#{File.realpath(video_directory)}#{File::SEPARATOR}")
          raise CaptureError, "browser recorder returned media outside its staging root"
        end
        result
      rescue JSON::ParserError, Errno::ENOENT => e
        raise CaptureError, "browser recorder returned invalid evidence: #{bounded_diagnostic(e)}"
      end

      def validate_media!(screenshot, video)
        unless File.file?(screenshot) && File.size(screenshot).positive? &&
               File.binread(screenshot, PNG_SIGNATURE.bytesize) == PNG_SIGNATURE
          raise CaptureError, "browser recorder did not produce a valid PNG"
        end
        unless File.file?(video) && File.size(video).positive?
          raise CaptureError, "browser recorder did not produce a non-empty video"
        end

        ffmpeg = Hive::InvokedBinary.which("ffmpeg")
        ffprobe = Hive::InvokedBinary.which("ffprobe")
        raise CaptureError, "ffmpeg is required for demo capture" unless ffmpeg
        raise CaptureError, "ffprobe is required for demo capture" unless ffprobe
        run_command!([ ffmpeg, "-version" ], capture: true)
        duration, = run_command!(
          [
            ffprobe, "-v", "error", "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1", video
          ],
          capture: true
        )
        unless Float(duration, exception: false)&.positive?
          raise CaptureError, "captured video is not playable"
        end
      end

      def publish_media!(staging:, media_root:, source_sha:, screenshot:, video:)
        suffix = source_sha[0, 12]
        destinations = [
          [ screenshot, File.join(media_root, "capture-#{suffix}.png") ],
          [ video, File.join(media_root, "capture-#{suffix}.webm") ]
        ]
        destinations.each do |source, destination|
          staged = File.join(staging, ".publish-#{File.basename(destination)}")
          FileUtils.cp(source, staged)
          File.chmod(0o600, staged)
          File.rename(staged, destination)
        end
        destinations.map(&:last)
      end

      def reject_manifest_secrets!(manifest)
        hits = Hive::SecretPatterns.scan(JSON.generate(manifest))
        return if hits.empty?

        names = hits.map { |hit| hit.fetch(:name) }.uniq.join(", ")
        raise CaptureError, "capture manifest contains secret-shaped content: #{names}"
      end

      def capture_runtime(source_root:, runtime_root:, lifecycle_token:)
        return @runtime_factory.call(
          source_root: source_root,
          runtime_root: runtime_root,
          lifecycle_token: lifecycle_token,
          environment: @environment
        ) if @runtime_factory

        Hive::Web::CaptureRuntime.new(
          source_root: source_root,
          runtime_root: runtime_root,
          lifecycle_token: lifecycle_token,
          environment: @environment
        )
      end

      def run_command!(argv, env: nil, chdir: nil, capture: false)
        command_env = env || {
          "PATH" => @environment.fetch("PATH", "/usr/local/bin:/usr/bin:/bin"),
          "LANG" => @environment["LANG"],
          "LC_ALL" => @environment["LC_ALL"],
          "GIT_CONFIG_NOSYSTEM" => "1",
          "GIT_TERMINAL_PROMPT" => "0"
        }.compact
        stdout, stderr, status = Open3.capture3(
          command_env,
          *argv,
          chdir: chdir || Dir.pwd,
          unsetenv_others: true
        )
        unless status.success?
          detail = stderr.to_s.empty? ? stdout : stderr
          raise CaptureError,
                "#{File.basename(argv.first)} failed: #{bounded_diagnostic(detail)}"
        end
        capture ? [ stdout, stderr ] : true
      rescue Errno::ENOENT => e
        raise CaptureError, "capture dependency is unavailable: #{e.message}"
      end

      def bounded_diagnostic(value)
        text = value.respond_to?(:message) ? value.message : value.to_s
        Hive::SecretPatterns.redact(
          text.to_s.b.byteslice(0, DIAGNOSTIC_MAX_BYTES).to_s
              .force_encoding(Encoding::UTF_8).scrub
        )
      end
    end
  end
end
