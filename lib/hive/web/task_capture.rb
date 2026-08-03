require "digest"
require "fileutils"
require "find"
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
require "hive/config"
require "hive/invoked_binary"
require "hive/secret_patterns"
require "hive/task"
require "hive/web/browser_bundle"
require "hive/web/capture_runtime"
require "hive/web/project_capture_provider"
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
      PROVIDER_SOURCE_SNAPSHOT_MAX_ENTRIES = 250_000
      PROVIDER_SOURCE_SNAPSHOT_MAX_BYTES = 1024 * 1024 * 1024
      PROVIDER_SOURCE_SNAPSHOT_TIMEOUT_SEC = 30
      PROVIDER_SOURCE_HASH_CHUNK_BYTES = 1024 * 1024
      PROVIDER_SOURCE_GIT_STDOUT_MAX_BYTES =
        Hive::Web::ProjectCaptureProvider::MAX_OUTPUT_BYTES
      PROVIDER_SOURCE_GIT_STDERR_MAX_BYTES =
        Hive::Web::ProjectCaptureProvider::MAX_DIAGNOSTIC_BYTES
      PNG_SIGNATURE = "\x89PNG\r\n\x1a\n".b.freeze
      BUILT_IN_RECORDER_INPUTS = %w[
        Gemfile.lock
        web/Gemfile
        web/Gemfile.lock
        web/package.json
        web/package-lock.json
        web/script/capture_task_page.cjs
        web/config/application.rb
        web/bin/rails
        web/Rakefile
        bin/hive
        lib/hive.rb
      ].freeze

      class CaptureError < Hive::Error; end

      class GitIndexFlagConsumer
        def initialize(max_entries:, max_record_bytes:)
          @max_entries = max_entries
          @max_record_bytes = max_record_bytes
          @entries = 0
          @buffer = +"".b
        end

        def write(chunk)
          @buffer << chunk.b
          while (separator = @buffer.index("\0".b))
            record = @buffer.slice!(0, separator)
            @buffer.slice!(0)
            validate_record!(record)
          end
          return if @buffer.bytesize <= @max_record_bytes

          raise CaptureError,
                "provider capture source Git index record exceeded its custody limit"
        end

        def finish
          validate_record!(@buffer) unless @buffer.empty?
        end

        private

        def validate_record!(record)
          @entries += 1
          if @entries > @max_entries
            raise CaptureError,
                  "provider capture source Git index exceeded the " \
                  "#{@max_entries}-entry custody limit"
          end
          match = /\A([A-Za-z?]) (.*)\z/m.match(record)
          unless match
            raise CaptureError,
                  "provider capture source Git index flags have an unsupported representation"
          end
          return if match[1] == "H"

          raise CaptureError,
                "provider capture source has non-default Git index flags " \
                "(assume-unchanged or skip-worktree)"
        end
      end
      private_constant :GitIndexFlagConsumer

      attr_reader :task

      def initialize(task_folder:, source_root: nil, output: $stdout,
                     error: $stderr, environment: ENV,
                     source_bundle: nil, browser_bundle: nil,
                     runtime_factory: nil, server_factory: nil,
                     project_config: nil, provider_factory: nil)
        @task = Hive::Task.new(File.expand_path(task_folder))
        @source_root_override = source_root && File.expand_path(source_root)
        @output = output
        @error = error
        @environment = environment.to_h
        @source_bundle = source_bundle
        @browser_bundle = browser_bundle
        @runtime_factory = runtime_factory
        @server_factory = server_factory
        @project_config = project_config || Hive::Config.load(@task.project_root)
        @provider_factory = provider_factory
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
        recorder = select_recorder(source_root)
        if recorder.fetch(:kind) == :built_in
          return capture_with_builtin(source_root: source_root, expected_head: expected_head)
        end

        capture_with_provider(
          source_root: source_root,
          expected_head: expected_head,
          provider_config: recorder.fetch(:config)
        )
      rescue Hive::Web::ProjectCaptureProvider::ProviderError => e
        raise CaptureError, bounded_diagnostic(e)
      rescue KeyError, JSON::ParserError, Timeout::Error, SystemCallError => e
        raise CaptureError, bounded_diagnostic(e)
      end

      private

      def capture_with_builtin(source_root:, expected_head:)
        session = staging = runtime_root = nil
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
          recorder: {
            "kind" => "built_in",
            "name" => "hivebox",
            "command" => [
              "hive", "web", "capture", "--task-folder", task.folder,
              "--source-root", source_root
            ]
          },
          environment_keys: Hive::Web::CaptureRuntime::DISCLOSED_ENV_KEYS,
          evidence: {
            "type" => "hivebox",
            "lock_digests" => source_entry.lock_digests,
            "cache_key" => source_entry.cache_key,
            "fixture_ids" => [ seed.fetch("project"), seed.fetch("task") ],
            "viewport" => { "width" => 1280, "height" => 800 },
            "accessibility_assertions" => browser_result.fetch("accessibility_assertions")
          },
          media_paths: final_paths,
          status: "captured",
          cleanup: {
            "processes" => "clean",
            "port" => "released",
            "runtime" => "cleaned"
          },
          started_at: started_at,
          finished_at: Time.now.utc
        )
        reject_manifest_secrets!(manifest)
        validate_manifest_budget!(manifest)
        runtime.publish_manifest!(task_folder: task.folder, manifest: manifest)
        manifest
      rescue KeyError, JSON::ParserError, Timeout::Error, SystemCallError => e
        raise CaptureError, bounded_diagnostic(e)
      ensure
        stop_server!(session) if session
        FileUtils.rm_rf(staging) if staging && File.exist?(staging)
        FileUtils.rm_rf(runtime_root) if runtime_root && File.exist?(runtime_root)
      end

      def capture_with_provider(source_root:, expected_head:, provider_config:)
        staging = runtime_root = nil
        published_paths = []
        previous_provider_paths = []
        manifest_published = false
        provider_executable = provider_config.fetch("command").fetch(0)
        source_snapshot = verify_provider_source!(
          source_root, expected_head, provider_executable: provider_executable
        )
        media_root = validated_media_root
        previous_provider_paths = retained_provider_media_paths(media_root)
        staging = Dir.mktmpdir(".capture-", media_root)
        runtime_root = Dir.mktmpdir("hive-project-capture-")
        provider = if @provider_factory
          @provider_factory.call(
            config: provider_config,
            environment: @environment
          )
        else
          Hive::Web::ProjectCaptureProvider.new(
            config: provider_config,
            environment: @environment
          )
        end
        result = call_provider_with_source_custody(
          provider,
          source_root: source_root,
          expected_head: expected_head,
          provider_executable: provider_executable,
          source_snapshot: source_snapshot,
          staging: staging,
          runtime_root: runtime_root
        )
        publication = provider_publication_plan(
          result.artifacts,
          media_root: media_root,
          source_sha: expected_head
        )
        runtime = capture_runtime(
          source_root: source_root,
          runtime_root: runtime_root,
          lifecycle_token: "provider-capture-#{SecureRandom.hex(12)}"
        )
        manifest = runtime.capture_manifest(
          task: task.slug,
          source_sha: expected_head,
          recorder: {
            "kind" => "project_provider",
            "name" => result.name,
            "command" => result.command
          },
          environment_keys: result.environment_keys,
          evidence: {
            "type" => "project_provider",
            "details" => result.evidence
          },
          artifacts: publication.map { |entry| entry.fetch("manifest") },
          status: "captured",
          cleanup: result.cleanup,
          diagnostic: result.diagnostic,
          started_at: result.started_at,
          finished_at: result.finished_at
        )
        reject_manifest_secrets!(manifest)
        validate_manifest_budget!(manifest)
        published_paths = publish_provider_media!(publication, staging: staging)
        runtime.publish_manifest!(task_folder: task.folder, manifest: manifest)
        manifest_published = true
        cleanup_superseded_provider_media!(
          previous_provider_paths,
          keep: publication.map { |entry| entry.fetch("destination") }
        )
        manifest
      ensure
        published_paths.each { |path| FileUtils.rm_f(path) } unless manifest_published
        FileUtils.rm_rf(staging) if staging && File.exist?(staging)
        FileUtils.rm_rf(runtime_root) if runtime_root && File.exist?(runtime_root)
      end

      def select_recorder(source_root)
        return { kind: :built_in } if @source_bundle
        return { kind: :built_in } if built_in_recorder_compatible?(source_root)

        unless project_provider_supported?
          raise CaptureError,
                "project-provider capture is unavailable on #{RUBY_PLATFORM}: " \
                "project capture provider custody requires Linux child-subreaper support"
        end

        provider = @project_config.dig("artifacts", "capture", "provider")
        return { kind: :provider, config: provider } if provider

        root_lock = regular_file?(File.join(source_root, "Gemfile.lock"))
        layout = root_lock ? "a conventional project root" : "a non-Hivebox project root"
        raise CaptureError,
              "no supported artifact capture provider is available for #{layout}: " \
              "the built-in recorder capability is absent and no project provider is configured. " \
              "Declare artifacts.capture.provider in #{File.join(task.project_root, '.hive-state', 'config.yml')} " \
              "with a project-owned recorder command."
      end

      def built_in_recorder_compatible?(source_root)
        BUILT_IN_RECORDER_INPUTS.all? do |relative|
          regular_file?(File.join(source_root, relative))
        end
      end

      def project_provider_supported?
        RUBY_PLATFORM.include?("linux")
      end

      def regular_file?(path)
        stat = File.lstat(path)
        stat.file? && !stat.symlink?
      rescue SystemCallError
        false
      end

      def call_provider_with_source_custody(provider, source_root:, expected_head:,
                                            provider_executable:, source_snapshot:,
                                            staging:, runtime_root:)
        result = nil
        provider_error = nil
        custody_error = nil
        begin
          result = provider.call(
            task: task.slug,
            source_root: source_root,
            source_sha: expected_head,
            staging_root: staging,
            runtime_root: runtime_root
          )
        rescue StandardError => e
          provider_error = e
        ensure
          begin
            verify_provider_source!(
              source_root,
              expected_head,
              provider_executable: provider_executable,
              expected_snapshot: source_snapshot
            )
          rescue StandardError => e
            custody_error = e
          end
        end

        if provider_error && custody_error
          raise CaptureError,
                "#{bounded_diagnostic(provider_error)}; source custody also failed: " \
                "#{bounded_diagnostic(custody_error)}"
        end
        raise provider_error if provider_error
        raise custody_error if custody_error

        result
      end

      def verify_provider_source!(source_root, expected_head, provider_executable:,
                                  expected_snapshot: nil)
        deadline = provider_custody_monotonic_now + PROVIDER_SOURCE_SNAPSHOT_TIMEOUT_SEC
        stat = File.lstat(source_root)
        if stat.symlink? || !stat.directory? || stat.uid != Process.uid
          raise CaptureError, "provider capture source must be an owned Git worktree directory"
        end
        top = capture_git!(
          source_root, "rev-parse", "--show-toplevel", deadline: deadline
        ).strip
        unless File.realpath(top) == File.realpath(source_root)
          raise CaptureError, "provider capture source does not match the Git worktree top level"
        end
        head = capture_git!(source_root, "rev-parse", "HEAD", deadline: deadline).strip
        unless head == expected_head
          raise CaptureError,
                "capture source HEAD #{head} does not match requirement #{expected_head}"
        end
        dirty = capture_git!(
          source_root, "status", "--porcelain=v1", "--untracked-files=all",
          "--ignore-submodules=none", deadline: deadline
        )
        unless dirty.empty?
          raise CaptureError,
                "source HEAD or cleanliness changed during project provider capture"
        end
        capture_git!(
          source_root, "ls-files", "--error-unmatch", "--", provider_executable,
          deadline: deadline
        )
        verify_provider_source_index_flags!(source_root, deadline: deadline)
        snapshot = provider_source_snapshot!(source_root, deadline: deadline)
        if expected_snapshot && snapshot != expected_snapshot
          raise CaptureError,
                "source custody changed during project provider capture, including ignored paths"
        end
        snapshot
      rescue Errno::ENOENT, Errno::ENOTDIR => e
        raise CaptureError, "provider capture source is unavailable: #{bounded_diagnostic(e)}"
      end

      def provider_source_snapshot!(source_root, deadline: nil)
        records = []
        logical_bytes = 0
        deadline ||= provider_custody_monotonic_now + PROVIDER_SOURCE_SNAPSHOT_TIMEOUT_SEC
        Find.find(source_root) do |path|
          enforce_provider_source_snapshot_deadline!(deadline)
          relative = path.delete_prefix("#{source_root}#{File::SEPARATOR}")
          next if relative.empty?
          if relative == ".git"
            Find.prune
            next
          end

          stat = File.lstat(path)
          if stat.file?
            remaining = PROVIDER_SOURCE_SNAPSHOT_MAX_BYTES - logical_bytes
            if stat.size > remaining
              raise CaptureError,
                    "provider capture source custody exceeds the " \
                    "#{PROVIDER_SOURCE_SNAPSHOT_MAX_BYTES}-byte logical-file limit; " \
                    "remove generated or ignored source files before capture"
            end
            logical_bytes += stat.size
          end
          records << provider_source_record(path, relative, stat, deadline: deadline)
          if records.length > PROVIDER_SOURCE_SNAPSHOT_MAX_ENTRIES
            raise CaptureError,
                  "provider capture source exceeds the #{PROVIDER_SOURCE_SNAPSHOT_MAX_ENTRIES}-entry custody limit"
          end
        end
        enforce_provider_source_snapshot_deadline!(deadline)
        digest = ::Digest::SHA256.new
        records.sort.each do |record|
          enforce_provider_source_snapshot_deadline!(deadline)
          digest << [ record.bytesize ].pack("Q>") << record
        end
        {
          count: records.length,
          logical_bytes: logical_bytes,
          digest: digest.hexdigest
        }.freeze
      rescue Errno::EACCES, Errno::EIO, Errno::ELOOP, Errno::ENAMETOOLONG => e
        raise CaptureError, "provider capture source could not be inventoried: #{bounded_diagnostic(e)}"
      end

      def provider_source_record(path, relative, stat, deadline:)
        fields = [
          relative.b,
          stat.ftype,
          stat.mode,
          stat.uid,
          stat.gid,
          stat.ino,
          stat.size,
          stat.mtime.to_i,
          stat.mtime.nsec,
          stat.ctime.to_i,
          stat.ctime.nsec
        ]
        case stat.ftype
        when "file"
          digest = provider_source_file_digest!(path, stat.size, deadline: deadline)
          after = File.lstat(path)
          unless provider_source_stat_identity(stat) == provider_source_stat_identity(after)
            raise CaptureError, "provider capture source changed while custody was inventoried"
          end
          fields << digest
        when "link"
          fields << File.readlink(path).b
        when "directory", "fifo", "socket", "characterSpecial", "blockSpecial"
          fields << stat.rdev
        else
          raise CaptureError,
                "provider capture source contains an unsupported #{stat.ftype} entry"
        end
        length_framed_record(fields)
      end

      def provider_source_file_digest!(path, expected_size, deadline:)
        digest = ::Digest::SHA256.new
        bytes_read = 0
        File.open(path, "rb") do |file|
          loop do
            enforce_provider_source_snapshot_deadline!(deadline)
            chunk = file.read(PROVIDER_SOURCE_HASH_CHUNK_BYTES)
            break unless chunk

            bytes_read += chunk.bytesize
            if bytes_read > expected_size
              raise CaptureError,
                    "provider capture source changed while custody was inventoried"
            end
            digest << chunk
          end
        end
        enforce_provider_source_snapshot_deadline!(deadline)
        unless bytes_read == expected_size
          raise CaptureError, "provider capture source changed while custody was inventoried"
        end

        digest.hexdigest
      end

      def enforce_provider_source_snapshot_deadline!(deadline)
        return if provider_custody_monotonic_now < deadline

        raise CaptureError,
              "provider capture source custody exceeded the " \
              "#{PROVIDER_SOURCE_SNAPSHOT_TIMEOUT_SEC}-second monotonic inventory deadline; " \
              "reduce the source tree before capture"
      end

      def provider_custody_monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def provider_source_stat_identity(stat)
        [
          stat.ftype, stat.mode, stat.uid, stat.gid, stat.ino, stat.size,
          stat.mtime.to_i, stat.mtime.nsec, stat.ctime.to_i, stat.ctime.nsec
        ]
      end

      def length_framed_record(fields)
        fields.each_with_object(+"".b) do |field, record|
          bytes = field.to_s.b
          record << [ bytes.bytesize ].pack("Q>") << bytes
        end
      end

      def verify_provider_source_index_flags!(source_root, deadline:)
        consumer = GitIndexFlagConsumer.new(
          max_entries: PROVIDER_SOURCE_SNAPSHOT_MAX_ENTRIES,
          max_record_bytes: PROVIDER_SOURCE_GIT_STDOUT_MAX_BYTES
        )
        capture_git!(
          source_root, "ls-files", "-v", "-f", "-z", deadline: deadline,
          stdout_consumer: consumer
        )
        nil
      end

      def capture_git!(source_root, *args, deadline: nil, stdout_consumer: nil)
        deadline ||= provider_custody_monotonic_now + PROVIDER_SOURCE_SNAPSHOT_TIMEOUT_SEC
        enforce_provider_source_snapshot_deadline!(deadline)
        env = {
          "PATH" => @environment.fetch("PATH", "/usr/local/bin:/usr/bin:/bin"),
          "LANG" => @environment["LANG"],
          "LC_ALL" => @environment["LC_ALL"],
          "GIT_CONFIG_NOSYSTEM" => "1",
          "GIT_LITERAL_PATHSPECS" => "1",
          "GIT_OPTIONAL_LOCKS" => "0",
          "GIT_TERMINAL_PROMPT" => "0"
        }.compact
        result = Hive::Web::ProjectCaptureProvider.capture_command_with_custody(
          argv: [
            "git", "-c", "core.hooksPath=/dev/null", "-c", "diff.external=",
            "-c", "core.fsmonitor=false", "-C", source_root, *args
          ],
          source_root: source_root,
          environment: env,
          deadline: deadline,
          stdout_consumer: stdout_consumer
        )
        if result["internal_error"]
          raise CaptureError,
                "provider capture Git custody failed: " \
                "#{bounded_diagnostic(result.fetch('internal_error'))}"
        end
        if result.fetch("cleanup_failed")
          raise CaptureError,
                "provider capture Git helper descendants could not be terminated"
        end
        if result["stdout_consumer_error"]
          raise CaptureError,
                bounded_diagnostic(result.fetch("stdout_consumer_error"))
        end
        enforce_provider_source_snapshot_deadline!(deadline) if result.fetch("timed_out")
        if result.fetch("stdout_overflow")
          raise CaptureError,
                "provider capture Git check stdout exceeded " \
                "#{PROVIDER_SOURCE_GIT_STDOUT_MAX_BYTES} bytes"
        end
        if result.fetch("stderr_overflow")
          raise CaptureError,
                "provider capture Git check stderr exceeded " \
                "#{PROVIDER_SOURCE_GIT_STDERR_MAX_BYTES} bytes"
        end
        if result.fetch("leftover_processes")
          raise CaptureError,
                "provider capture Git check left child processes running"
        end

        status = result.fetch("status")
        unless status.fetch("success")
          exit_detail = if status.fetch("signaled")
            "signal #{status.fetch('termsig').inspect}"
          else
            "exit #{status.fetch('exitstatus').inspect}"
          end
          detail = bounded_diagnostic(result.fetch("stderr"))
          suffix = detail.empty? ? "" : ": #{detail}"
          raise CaptureError,
                "provider capture Git check failed (#{exit_detail})#{suffix}"
        end
        result.fetch("stdout")
      rescue Hive::Web::ProjectCaptureProvider::ProviderError => e
        raise CaptureError, "provider capture Git custody failed: #{bounded_diagnostic(e)}"
      end

      def provider_publication_plan(artifacts, media_root:, source_sha:)
        artifacts.sort_by { |artifact| artifact.fetch("file") }.map do |artifact|
          original_name = artifact.fetch("file")
          extension = File.extname(original_name).downcase
          name_digest = ::Digest::SHA256.hexdigest(original_name)
          destination_name =
            "capture-provider-#{source_sha}-#{artifact.fetch('sha256')}-#{name_digest}#{extension}"
          {
            "source" => artifact.fetch("source_path"),
            "destination" => File.join(media_root, destination_name),
            "manifest" => {
              "file" => destination_name,
              "bytes" => artifact.fetch("bytes"),
              "sha256" => artifact.fetch("sha256")
            }
          }
        end
      end

      def retained_provider_media_paths(media_root)
        manifest_path = File.join(media_root, "capture-manifest.json")
        stat = File.lstat(manifest_path)
        return [] unless stat.file? && !stat.symlink?
        return [] if stat.size > Hive::ARTIFACT_CAPTURE_MANIFEST_MAX_BYTES

        manifest = JSON.parse(
          File.binread(manifest_path, Hive::ARTIFACT_CAPTURE_MANIFEST_MAX_BYTES)
        )
        return [] unless manifest.is_a?(Hash)
        return [] unless manifest["schema"] == "hive-artifact-capture"
        return [] unless manifest["schema_version"] == 2
        recorder = manifest["recorder"]
        return [] unless recorder.is_a?(Hash)
        return [] unless recorder["kind"] == "project_provider"

        Array(manifest["artifacts"]).filter_map do |artifact|
          next unless artifact.is_a?(Hash)

          filename = artifact["file"].to_s
          next unless File.basename(filename) == filename
          next unless filename.start_with?("capture-provider-")
          next unless filename.match?(Hive::Web::ProjectCaptureProvider::MEDIA_FILE)

          File.join(media_root, filename)
        end
      rescue JSON::ParserError, SystemCallError
        []
      end

      def cleanup_superseded_provider_media!(previous_paths, keep:)
        (Array(previous_paths) - Array(keep)).each do |path|
          FileUtils.rm_f(path)
        rescue SystemCallError => e
          @error.puts(
            "hive: retained superseded provider media #{File.basename(path)}: " \
            "#{bounded_diagnostic(e)}"
          )
        end
      end

      def publish_provider_media!(publication, staging:)
        published = []
        publication.each do |entry|
          destination = entry.fetch("destination")
          manifest = entry.fetch("manifest")
          if File.exist?(destination) || File.symlink?(destination)
            stat = File.lstat(destination)
            reusable = stat.file? && !stat.symlink? && stat.uid == Process.uid &&
                       stat.size == manifest.fetch("bytes") &&
                       ::Digest::SHA256.file(destination).hexdigest == manifest.fetch("sha256")
            raise CaptureError, "capture artifact destination collision: #{destination}" unless reusable
            next
          end

          staged = File.join(staging, ".publish-#{File.basename(destination)}")
          File.open(staged, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |output|
            File.open(entry.fetch("source"), "rb") do |input|
              IO.copy_stream(input, output)
            end
            output.flush
            output.fsync
          end
          File.rename(staged, destination)
          published << destination
        ensure
          FileUtils.rm_f(staged) if staged
        end
        published
      rescue StandardError
        published.each { |path| FileUtils.rm_f(path) }
        raise
      end

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
        server_output = readiness_writer.dup
        log = File.open(log_path, File::WRONLY | File::CREAT | File::EXCL, 0o600)
        server = if @server_factory
          @server_factory.call(
            source_root: source_root,
            runtime_root: runtime_root,
            lifecycle_token: lifecycle_token,
            control_io: control_reader,
            output: server_output,
            error: log,
            environment: @environment
          )
        else
          Hive::Commands::Web::CaptureServer.new(
            source_root: source_root,
            runtime_root: runtime_root,
            lifecycle_token: lifecycle_token,
            control_io: control_reader,
            output: server_output,
            error: log,
            environment: @environment
          )
        end
        server_errors = []
        thread = Thread.new do
          server.call
        rescue StandardError => e
          server_errors << e
        ensure
          server_output.close unless server_output.closed?
        end
        thread.report_on_exception = false
        readiness_writer.close
        line = Timeout.timeout(START_TIMEOUT_SEC) { readiness_reader.gets }
        unless line
          thread.value
          error = server_errors.first
          raise CaptureError, capture_server_diagnostic(error, log, log_path) if error

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
          server_errors: server_errors,
          base_url: URI(receipt.fetch("readiness_url")).then do |uri|
            "http://127.0.0.1:#{uri.port}"
          end
        }
      rescue StandardError
        control_writer&.close
        control_reader&.close
        readiness_reader&.close
        readiness_writer&.close
        server_output&.close
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
        error = session.fetch(:server_errors).first
        raise CaptureError, capture_server_diagnostic(error, session.fetch(:log), session.fetch(:log).path) if
          error
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
          RbConfig.ruby, source_entry.bundler_executable, "exec",
          RbConfig.ruby, "-I#{File.join(source_root, 'lib')}",
          File.join(source_root, "bin", "hive")
        ]
        run_command!([ *hive, "init", project_root ], env: cli_env, chdir: source_root)
        run_command!(
          [ *hive, "new", project_name, "Synthetic browser capture task" ],
          env: cli_env,
          chdir: source_root
        )
        inbox_dir = "1-inbox" # coding-scoped: capture fixture uses the default coding workflow
        slug = Dir[File.join(project_root, ".hive-state", "stages", inbox_dir, "*")]
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

      def validate_manifest_budget!(manifest)
        bytes = JSON.generate(manifest).bytesize + 1
        return bytes if bytes <= Hive::ARTIFACT_CAPTURE_MANIFEST_PRODUCER_MAX_BYTES

        raise CaptureError,
              "capture manifest is #{bytes} bytes and exceeds the producer limit of " \
              "#{Hive::ARTIFACT_CAPTURE_MANIFEST_PRODUCER_MAX_BYTES} bytes below the shared " \
              "consumer ceiling of #{Hive::ARTIFACT_CAPTURE_MANIFEST_MAX_BYTES} bytes; " \
              "reduce artifacts.capture.provider command or evidence data"
      rescue JSON::GeneratorError, TypeError => e
        raise CaptureError, "capture manifest could not be serialized: #{bounded_diagnostic(e)}"
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

      def capture_server_diagnostic(error, log, log_path)
        log.flush
        tail = File.open(log_path, "rb") do |file|
          file.seek([ file.size - DIAGNOSTIC_MAX_BYTES, 0 ].max)
          file.read(DIAGNOSTIC_MAX_BYTES)
        end
        [ error.message, tail ].reject { |value| value.to_s.empty? }
                               .map { |value| bounded_diagnostic(value) }
                               .join("\n")
      rescue SystemCallError, IOError
        bounded_diagnostic(error)
      end
    end
  end
end
