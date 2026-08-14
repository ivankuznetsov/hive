require "fileutils"
require "json"
require "timeout"
require "uri"
require "hive/commands/web/capture_server"
require "hive/web/capture_runtime"

module Hive
  module Artifacts
    # Controller-owned Hive Web server for outcome evidence. It reuses the
    # production capture runtime's clean-source, private dependency cache, and
    # process-group teardown rather than asking a producer to improvise a
    # writable Rails launch from the frozen worktree.
    class ManagedWebServer
      START_TIMEOUT_SECONDS = 600
      STOP_TIMEOUT_SECONDS = Hive::Web::CaptureRuntime::CLEANUP_TIMEOUT_SEC + 15
      MAX_DIAGNOSTIC_BYTES = 16 * 1024

      attr_reader :receipt

      class ServerError < Hive::Error; end

      def initialize(source_root:, source_sha:, writable_root:, port: 0,
                     environment: ENV, lifecycle_token:, server_factory: nil)
        @source_root = File.expand_path(source_root)
        @source_sha = source_sha.to_s
        @writable_root = File.expand_path(writable_root)
        @runtime_root = File.join(@writable_root, ".hive-web-runtime")
        @log_path = File.join(@writable_root, ".hive-web-server.log")
        @port = Integer(port)
        @environment = environment.to_h
        @lifecycle_token = lifecycle_token.to_s
        @server_factory = server_factory
        @errors = []
      end

      def start!
        FileUtils.mkdir_p(@writable_root, mode: 0o700)
        @control_reader, @control_writer = IO.pipe
        @readiness_reader, readiness_writer = IO.pipe
        server_output = readiness_writer.dup
        @log = File.open(
          @log_path, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600
        )
        server = build_server(control_io: @control_reader, output: server_output)
        @thread = Thread.new do
          server.call
        rescue StandardError => e
          @errors << e
        ensure
          server_output.close unless server_output.closed?
        end
        @thread.report_on_exception = false
        readiness_writer.close
        line = Timeout.timeout(START_TIMEOUT_SECONDS) { @readiness_reader.gets }
        raise ServerError, diagnostic("capture server returned no readiness receipt") unless line

        readiness = JSON.parse(line)
        validate_readiness!(readiness)
        @receipt = {
          "driver" => "hive-web-capture-runtime",
          "status" => "ready",
          "app_port" => Integer(URI(readiness.fetch("readiness_url")).port),
          "app_endpoint" => readiness.fetch("readiness_url").sub(%r{/health\z}, ""),
          "hive_home" => File.join(@runtime_root, "hive-home"),
          "source_sha" => readiness.fetch("source_sha"),
          "cache_key" => readiness.fetch("cache_key")
        }
      rescue StandardError => e
        cleanup_error = begin
          close
          nil
        rescue StandardError => close_error
          close_error
        end
        message = e.is_a?(ServerError) ? e.message :
          diagnostic("capture server startup failed: #{e.message}")
        if cleanup_error
          message = "#{message}; cleanup: #{cleanup_error.message}"
        end
        raise ServerError, message
      end

      def close
        @control_writer&.close unless @control_writer&.closed?
        if @thread
          Timeout.timeout(STOP_TIMEOUT_SECONDS) { @thread.value }
          raise ServerError, diagnostic("capture server teardown failed") if @errors.any?
        end
        true
      rescue Timeout::Error
        @thread&.kill
        @thread&.join
        raise ServerError, diagnostic("capture server teardown timed out")
      ensure
        [ @control_writer, @control_reader, @readiness_reader, @log ].each do |io|
          io&.close unless io&.closed?
        rescue IOError
          nil
        end
      end

      private

      def build_server(control_io:, output:)
        attributes = {
          source_root: @source_root,
          runtime_root: @runtime_root,
          lifecycle_token: @lifecycle_token,
          port: @port,
          control_io: control_io,
          output: output,
          error: @log,
          environment: @environment
        }
        return @server_factory.call(**attributes) if @server_factory

        Hive::Commands::Web::CaptureServer.new(**attributes)
      end

      def validate_readiness!(readiness)
        uri = URI(readiness.fetch("readiness_url"))
        valid = readiness["schema"] == Hive::Web::CaptureRuntime::SCHEMA &&
          readiness["schema_version"] == Hive::Web::CaptureRuntime::SCHEMA_VERSION &&
          readiness["lifecycle_id"] == @lifecycle_token &&
          readiness["source_sha"] == @source_sha &&
          uri.scheme == "http" && uri.host == "127.0.0.1" &&
          uri.path == "/health" && uri.port.between?(1, 65_535) &&
          (@port.zero? || uri.port == @port)
        raise ServerError, "capture server returned an invalid ownership receipt" unless valid
      rescue URI::InvalidURIError
        raise ServerError, "capture server returned an invalid ownership receipt"
      end

      def diagnostic(prefix)
        error = @errors.first
        details = begin
          @log&.flush
          File.read(@log_path, MAX_DIAGNOSTIC_BYTES).to_s
        rescue SystemCallError, IOError
          ""
        end
        [ prefix, error&.message, details ].compact.reject(&:empty?).join(": ")
          .byteslice(0, MAX_DIAGNOSTIC_BYTES).to_s.scrub
      end
    end
  end
end
