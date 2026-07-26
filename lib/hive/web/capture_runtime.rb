require "digest"
require "fileutils"
require "json"
require "net/http"
require "rbconfig"
require "securerandom"
require "socket"
require "time"
require "uri"
require "hive"
require "hive/atomic_file"
require "hive/lock"
require "hive/process_kill"
require "hive/web/source_bundle"

module Hive
  module Web
    # Owns the credential-free runtime used by local browser capture. It never
    # reuses the operator's HOME, Hive registry, Rails databases, Bundler
    # settings, service units, or long-lived web process.
    class CaptureRuntime
      SCHEMA = "hive-web-capture-runtime".freeze
      SCHEMA_VERSION = 1
      ARTIFACT_SCHEMA = "hive-artifact-capture".freeze
      ARTIFACT_SCHEMA_VERSION = 1
      BIND = "127.0.0.1".freeze
      READY_TIMEOUT_SEC = 60
      CLEANUP_TIMEOUT_SEC = 5
      OWNER_FILE = ".hive-web-capture-owner.json".freeze
      SAFE_AMBIENT_KEYS = %w[PATH LANG LC_ALL LC_CTYPE TZ SSL_CERT_FILE SSL_CERT_DIR].freeze
      DISCLOSED_ENV_KEYS = %w[
        HOME XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME XDG_STATE_HOME
        HIVE_HOME HIVE_WEB_STORAGE_DIR HIVE_WEB_ASSETS_DIR HIVE_WEB_LOCAL_LOOPBACK
        HIVE_WEB_CAPTURE_BIND HIVE_WEB_CAPTURE_PORT BUNDLE_GEMFILE
        BUNDLE_PATH BUNDLE_APP_CONFIG BUNDLE_FROZEN BUNDLE_DEPLOYMENT
        BUNDLE_DISABLE_SHARED_GEMS BUNDLE_USER_HOME GEM_HOME GEM_PATH
        RAILS_ENV SECRET_KEY_BASE HIVE_CLI_ROOT TMPDIR
        PLAYWRIGHT_BROWSERS_PATH HIVE_PLAYWRIGHT_MODULE NODE_OPTIONS NODE_PATH
      ].freeze

      class OwnershipError < Hive::Error; end
      class RuntimeError < Hive::Error; end

      Readiness = Data.define(
        :lifecycle_id, :pid, :process_start_time, :process_group,
        :port, :readiness_url, :source_sha, :cache_key, :lock_digests,
        :runtime_root, :storage_root, :started_at
      ) do
        def to_h
          {
            "schema" => CaptureRuntime::SCHEMA,
            "schema_version" => CaptureRuntime::SCHEMA_VERSION,
            "lifecycle_id" => lifecycle_id,
            "pid" => pid,
            "process_start_time" => process_start_time,
            "process_group" => process_group,
            "port" => port,
            "readiness_url" => readiness_url,
            "source_sha" => source_sha,
            "cache_key" => cache_key,
            "lock_digests" => lock_digests,
            "runtime_root" => runtime_root,
            "storage_root" => storage_root,
            "started_at" => started_at
          }
        end
      end

      attr_reader :runtime_root, :source_root, :lifecycle_token

      def initialize(source_root:, runtime_root:, environment: ENV,
                     lifecycle_token:, cache_root: nil, clock: -> { Time.now.utc },
                     source_bundle: nil)
        @source_root = File.expand_path(source_root)
        @runtime_root = File.expand_path(runtime_root)
        @ambient_environment = environment.to_h
        @lifecycle_token = lifecycle_token.to_s
        @cache_root = cache_root
        @clock = clock
        raise OwnershipError, "capture lifecycle token is required" unless
          @lifecycle_token.match?(/\A[A-Za-z0-9._-]{8,128}\z/)

        @source_bundle = source_bundle
        @claimed = false
      end

      def claimed? = @claimed

      def prepare!
        ensure_private_runtime!
        cleanup_stale_lifecycle!
        source_bundle.ensure!
      end

      def environment(bundle_path:, port:)
        ensure_private_runtime!
        home = private_dir("home")
        xdg = private_dir("xdg")
        storage = private_dir("rails-storage")
        assets = private_dir("assets")
        tmp = private_dir("tmp")
        bundle_config = private_dir("bundle-config")
        bundle_home = private_dir("bundle-home")
        hive_home = private_dir("hive-home")
        env = SAFE_AMBIENT_KEYS.each_with_object({}) do |name, allowed|
          value = @ambient_environment[name]
          allowed[name] = value if value && !value.empty?
        end
        env.merge!(
          "HOME" => home,
          "XDG_CONFIG_HOME" => File.join(xdg, "config"),
          "XDG_CACHE_HOME" => File.join(xdg, "cache"),
          "XDG_DATA_HOME" => File.join(xdg, "data"),
          "XDG_STATE_HOME" => File.join(xdg, "state"),
          "HIVE_HOME" => hive_home,
          "HIVE_WEB_STORAGE_DIR" => storage,
          "HIVE_WEB_ASSETS_DIR" => assets,
          "HIVE_WEB_LOCAL_LOOPBACK" => "1",
          "HIVE_WEB_CAPTURE_BIND" => BIND,
          "HIVE_WEB_CAPTURE_PORT" => Integer(port).to_s,
          "BUNDLE_GEMFILE" => File.join(@source_root, "web", "Gemfile"),
          "BUNDLE_PATH" => File.expand_path(bundle_path),
          "BUNDLE_APP_CONFIG" => bundle_config,
          "BUNDLE_FROZEN" => "1",
          "BUNDLE_DEPLOYMENT" => "1",
          "BUNDLE_DISABLE_SHARED_GEMS" => "1",
          "BUNDLE_USER_HOME" => bundle_home,
          "GEM_HOME" => nil,
          "GEM_PATH" => nil,
          "RAILS_ENV" => "production",
          "SECRET_KEY_BASE" => SecureRandom.hex(64),
          "HIVE_CLI_ROOT" => @source_root,
          "TMPDIR" => tmp,
          "RUBYOPT" => nil,
          "RUBYLIB" => nil
        )
        env.compact!
        env.each_value do |value|
          next unless value.is_a?(String) && value.start_with?(@runtime_root)

          FileUtils.mkdir_p(value, mode: 0o700) unless File.extname(value) == ".lock"
        end
        env
      end

      def allocate_port(requested = 0)
        port = Integer(requested)
        raise RuntimeError, "capture port must be between 0 and 65535" unless (0..65_535).cover?(port)

        server = TCPServer.new(BIND, port)
        selected = server.addr.fetch(1)
        [ selected, server ]
      rescue Errno::EADDRINUSE
        raise RuntimeError, "capture port #{port} is already in use"
      end

      def write_lifecycle!(pid:, process_start_time:, process_group:, port:, source_sha:)
        document = {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "token" => @lifecycle_token,
          "pid" => Integer(pid),
          "process_start_time" => process_start_time.to_s,
          "process_group" => Integer(process_group),
          "port" => Integer(port),
          "source_sha" => source_sha.to_s,
          "created_at" => iso_time(@clock.call)
        }
        write_json_atomic(lifecycle_path, document)
        document
      end

      def cleanup_stale_lifecycle!
        return { "status" => "none" } unless File.exist?(lifecycle_path)

        document = read_lifecycle
        unless secure_equal?(document["token"].to_s, @lifecycle_token)
          raise OwnershipError, "refusing stale capture cleanup: lifecycle ownership token does not match"
        end
        pid = Integer(document["pid"], exception: false)
        if pid && Hive::ProcessKill.pid_alive?(pid)
          result = Hive::ProcessKill.terminate_process_group(
            pid,
            recorded_start_time: document["process_start_time"],
            grace_seconds: CLEANUP_TIMEOUT_SEC
          )
          unless result.killed || result.skipped_reason == "not_alive"
            raise OwnershipError,
                  "refusing stale capture cleanup: process ownership was not proven (#{result.skipped_reason})"
          end
        end
        FileUtils.rm_f(lifecycle_path)
        { "status" => "cleaned", "pid" => pid }
      rescue JSON::ParserError, TypeError
        raise OwnershipError, "refusing stale capture cleanup: lifecycle receipt is invalid"
      end

      def capture_manifest(task:, source_sha:, lock_digests:, cache_key:, command:,
                           fixture_ids:, media_paths:, status:, cleanup:,
                           viewport: { "width" => 1280, "height" => 800 },
                           accessibility_assertions: [], diagnostic: nil,
                           started_at: nil, finished_at: nil)
        now = @clock.call
        started_at ||= now
        finished_at ||= now
        artifacts = Array(media_paths).sort_by { |path| File.basename(path) }.map do |path|
          {
            "file" => File.basename(path),
            "bytes" => File.size(path),
            "sha256" => ::Digest::SHA256.file(path).hexdigest
          }
        end
        {
          "schema" => ARTIFACT_SCHEMA,
          "schema_version" => ARTIFACT_SCHEMA_VERSION,
          "status" => status.to_s,
          "task" => task.to_s,
          "source_sha" => source_sha.to_s,
          "lock_digests" => lock_digests.to_h.sort.to_h,
          "cache_key" => cache_key.to_s,
          "command" => Array(command).map(&:to_s),
          "environment_keys" => DISCLOSED_ENV_KEYS.sort,
          "fixture_ids" => Array(fixture_ids).map(&:to_s).sort,
          "started_at" => iso_time(started_at),
          "finished_at" => iso_time(finished_at),
          "viewport" => viewport.to_h.sort.to_h,
          "accessibility_assertions" => Array(accessibility_assertions).map(&:to_s).sort,
          "artifacts" => artifacts,
          "cleanup" => cleanup.to_h.sort.to_h,
          "diagnostic" => redacted(diagnostic)
        }
      end

      def publish_manifest!(task_folder:, manifest:)
        media_root = File.join(File.expand_path(task_folder), "media")
        FileUtils.mkdir_p(media_root, mode: 0o700)
        write_json_atomic(
          File.join(media_root, "capture-manifest.json"),
          manifest
        )
      end

      def cleanup_runtime!(preserve_diagnostics: true)
        verify_runtime_claim!
        FileUtils.rm_f(lifecycle_path)
        %w[rails-storage assets tmp hive-home home xdg bundle-config bundle-home].each do |basename|
          next if preserve_diagnostics && basename == "rails-storage"

          FileUtils.rm_rf(File.join(@runtime_root, basename))
        end
        { "processes" => "clean", "port" => "released", "runtime" => "cleaned" }
      end

      def lifecycle_path
        File.join(@runtime_root, "lifecycle.json")
      end

      private

      def source_bundle
        @source_bundle ||= Hive::Web::SourceBundle.new(
          source_root: @source_root,
          cache_root: @cache_root
        )
      end

      def ensure_private_runtime!
        FileUtils.mkdir_p(@runtime_root, mode: 0o700)
        stat = File.lstat(@runtime_root)
        raise OwnershipError, "capture runtime must not be a symlink" if stat.symlink?
        raise OwnershipError, "capture runtime has foreign ownership" unless stat.uid == Process.uid

        claim_runtime!
        FileUtils.chmod(0o700, @runtime_root)
      end

      def claim_runtime!
        path = File.join(@runtime_root, OWNER_FILE)
        if File.exist?(path) || File.symlink?(path)
          document = read_owner(path)
          unless secure_equal?(document.fetch("token").to_s, @lifecycle_token)
            raise OwnershipError,
                  "capture runtime belongs to a different lifecycle token"
          end
          @claimed = true
          return
        end
        unless Dir.children(@runtime_root).empty?
          raise OwnershipError,
                "unclaimed capture runtime must be empty"
        end

        write_json_atomic(
          path,
          {
            "schema" => "hive-web-capture-owner",
            "schema_version" => 1,
            "token" => @lifecycle_token
          }
        )
        @claimed = true
      end

      def verify_runtime_claim!
        raise OwnershipError, "capture runtime was not claimed by this lifecycle" unless @claimed

        document = read_owner(File.join(@runtime_root, OWNER_FILE))
        unless secure_equal?(document.fetch("token").to_s, @lifecycle_token)
          raise OwnershipError, "capture runtime ownership changed before cleanup"
        end
        true
      end

      def read_owner(path)
        stat = File.lstat(path)
        unless stat.file? && !stat.symlink? && stat.uid == Process.uid &&
               stat.size <= 4 * 1024
          raise OwnershipError, "capture runtime ownership receipt is invalid"
        end
        document = JSON.parse(File.read(path))
        unless document.is_a?(Hash) &&
               document["schema"] == "hive-web-capture-owner" &&
               document["schema_version"] == 1
          raise OwnershipError, "capture runtime ownership receipt is invalid"
        end
        document
      rescue JSON::ParserError, KeyError, SystemCallError
        raise OwnershipError, "capture runtime ownership receipt is invalid"
      end

      def private_dir(name)
        path = File.join(@runtime_root, name)
        FileUtils.mkdir_p(path, mode: 0o700)
        FileUtils.chmod(0o700, path)
        path
      end

      def read_lifecycle
        stat = File.lstat(lifecycle_path)
        raise OwnershipError, "capture lifecycle receipt must be a regular file" unless stat.file? && !stat.symlink?
        raise OwnershipError, "capture lifecycle receipt has foreign ownership" unless stat.uid == Process.uid
        raise OwnershipError, "capture lifecycle receipt is too large" if stat.size > 16 * 1024

        JSON.parse(File.read(lifecycle_path))
      rescue Errno::ENOENT
        {}
      end

      def secure_equal?(left, right)
        return false unless left.bytesize == right.bytesize

        result = 0
        left.bytes.zip(right.bytes) { |a, b| result |= a ^ b }
        result.zero?
      end

      def redacted(value)
        return nil if value.nil?

        require "hive/secret_patterns"
        Hive::SecretPatterns.redact(value.to_s)[0, 16 * 1024]
      end

      def iso_time(value)
        value.respond_to?(:utc) ? value.utc.iso8601(6) : Time.parse(value.to_s).utc.iso8601(6)
      end

      def write_json_atomic(path, document)
        FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
        tmp = "#{path}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}"
        File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.write("#{JSON.generate(document)}\n")
          file.flush
          file.fsync
        end
        File.rename(tmp, path)
      ensure
        FileUtils.rm_f(tmp) if tmp
      end
    end
  end
end
