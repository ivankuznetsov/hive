require "digest"
require "fileutils"
require "io/console"
require "json"
require "pty"
require "rbconfig"
require "shellwords"
require "hive/atomic_file"
require "hive/web/project_capture_provider"

module Hive
  module Artifacts
    # Native terminal evidence recorder. It launches one argv command directly
    # under a private PTY and emits both an asciinema v2 original and a bounded,
    # ANSI-free text review representation.
    class TerminalRecorder
      MAX_OUTPUT_BYTES = 4 * 1024 * 1024
      DEFAULT_TIMEOUT_SECONDS = 30
      DEFAULT_WIDTH = 120
      DEFAULT_HEIGHT = 30
      READ_BYTES = 16 * 1024
      ANSI = /(?:\e\][^\a]*(?:\a|\e\\)|\e\[[0-?]*[ -\/]*[@-~])/m

      class CaptureError < Hive::Error; end

      def initialize(argv:, cwd:, cast_path:, review_path:, environment: {},
                     timeout_seconds: DEFAULT_TIMEOUT_SECONDS,
                     width: DEFAULT_WIDTH, height: DEFAULT_HEIGHT,
                     clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @argv = Array(argv).map(&:to_s)
        @cwd = File.expand_path(cwd)
        @cast_path = File.expand_path(cast_path)
        @review_path = File.expand_path(review_path)
        @environment = environment.to_h.transform_keys(&:to_s)
        @timeout_seconds = Float(timeout_seconds)
        @width = Integer(width)
        @height = Integer(height)
        @clock = clock
      end

      def record!
        validate!
        @owns_representation_paths = true
        result = capture_with_custody
        return result if result

        raise CaptureError, "terminal capture returned no durable result"
      rescue CaptureError
        cleanup_representations
        raise
      rescue Hive::Web::ProjectCaptureProvider::ProviderError => e
        cleanup_representations
        raise CaptureError, "terminal capture custody failed: #{e.message}"
      rescue JSON::ParserError, KeyError => e
        cleanup_representations
        raise CaptureError, "terminal capture worker returned invalid output: #{e.message}"
      rescue ArgumentError, TypeError => e
        cleanup_representations
        raise CaptureError, "terminal capture configuration is invalid: #{e.message}"
      end

      private

      def record_direct!
        started = @clock.call
        events = []
        output = +"".b
        status = capture(started, events, output)
        write_representations(events, output, status)
      rescue ArgumentError, TypeError => e
        raise CaptureError, "terminal capture configuration is invalid: #{e.message}"
      end

      def capture_with_custody
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout_seconds + 1
        result = Hive::Web::ProjectCaptureProvider.capture_command_with_custody(
          argv: [ RbConfig.ruby, "-I", File.expand_path("../..", __dir__), __FILE__, "--worker" ],
          request: worker_request,
          source_root: @cwd,
          environment: { "PATH" => ENV.fetch("PATH", "/usr/local/bin:/usr/bin:/bin") },
          deadline: deadline
        )
        status = result.fetch("status")
        unless !result["internal_error"] && !result["timed_out"] &&
               !result["cleanup_failed"] && !result["stdout_overflow"] &&
               !result["stderr_overflow"] && !result["leftover_processes"] &&
               status.fetch("success")
          raise CaptureError, custody_diagnostic(result)
        end

        JSON.parse(result.fetch("stdout"))
      end

      def worker_request
        {
          "argv" => @argv,
          "cwd" => @cwd,
          "cast_path" => @cast_path,
          "review_path" => @review_path,
          "environment" => @environment,
          "timeout_seconds" => @timeout_seconds,
          "width" => @width,
          "height" => @height
        }
      end

      def custody_diagnostic(result)
        return "terminal capture exceeded #{@timeout_seconds.to_i} seconds" if result["timed_out"]
        return "terminal capture left descendant processes running" if result["leftover_processes"]
        return "terminal capture descendants could not be terminated" if result["cleanup_failed"]
        return "terminal capture worker output exceeded its bound" if result["stdout_overflow"] || result["stderr_overflow"]

        detail = result["stderr"].to_s.strip
        detail.empty? ? "terminal capture worker failed" : "terminal capture worker failed: #{detail.byteslice(0, 512)}"
      end

      def cleanup_representations
        return unless @owns_representation_paths

        [ @cast_path, @review_path ].each do |path|
          File.unlink(path)
        rescue Errno::ENOENT
          nil
        end
      end

      def validate!
        raise CaptureError, "terminal capture command is required" if @argv.empty? || @argv.first.empty?
        raise CaptureError, "terminal capture cwd is unavailable" unless File.directory?(@cwd)
        unless @timeout_seconds.positive? && @timeout_seconds <= 300
          raise CaptureError, "terminal capture timeout must be between 0 and 300 seconds"
        end
        unless @width.between?(20, 500) && @height.between?(5, 200)
          raise CaptureError, "terminal capture dimensions are outside the supported range"
        end
        if @cast_path == @review_path
          raise CaptureError, "terminal capture representations need distinct paths"
        end
        [ @cast_path, @review_path ].each do |path|
          parent = File.dirname(path)
          FileUtils.mkdir_p(parent, mode: 0o700)
          raise CaptureError, "terminal capture parent is unavailable" unless File.directory?(parent)
          if File.exist?(path) || File.symlink?(path)
            raise CaptureError, "terminal capture representation already exists"
          end
        end
      end

      def capture(started, events, output)
        reaped = false
        reader, writer, pid = PTY.spawn(
          @environment, *@argv, chdir: @cwd, unsetenv_others: true
        )
        reader.winsize = [ @height, @width ]
        writer.close
        deadline = started + @timeout_seconds
        process_status = nil
        loop do
          drain(reader, started, events, output) if IO.select([ reader ], nil, nil, 0.05)
          waited = Process.waitpid2(pid, Process::WNOHANG)
          if waited
            process_status = waited.last
            reaped = true
            break
          end
          if @clock.call >= deadline
            terminate_group(pid)
            Process.waitpid(pid)
            reaped = true
            raise CaptureError, "terminal capture exceeded #{@timeout_seconds.to_i} seconds"
          end
        end
        drain(reader, started, events, output)
        process_status
      rescue Errno::ENOENT
        raise CaptureError, "terminal capture executable is unavailable: #{@argv.first}"
      ensure
        unless reaped || !pid
          terminate_group(pid)
          begin
            Process.waitpid(pid)
          rescue Errno::ECHILD
            nil
          end
        end
        reader&.close unless reader&.closed?
        writer&.close unless writer&.closed?
      end

      def drain(master, started, events, output)
        loop do
          chunk = master.read_nonblock(READ_BYTES)
          output << chunk
          if output.bytesize > MAX_OUTPUT_BYTES
            raise CaptureError, "terminal capture exceeds #{MAX_OUTPUT_BYTES} bytes"
          end
          text = chunk.dup.force_encoding(Encoding::UTF_8).scrub
          events << [ (@clock.call - started).round(6), "o", text ] unless text.empty?
        rescue IO::WaitReadable
          break
        rescue EOFError, Errno::EIO
          break
        end
      end

      def terminate_group(pid)
        Process.kill("TERM", -pid)
        sleep(0.05)
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH
        nil
      end

      def write_representations(events, output, status)
        header = {
          "version" => 2, "width" => @width, "height" => @height,
          "timestamp" => Time.now.to_i, "env" => { "TERM" => "xterm-256color" }
        }
        cast = ([ header ] + events).map { |record| JSON.generate(record) }.join("\n") << "\n"
        exit_status = status.exitstatus || 128 + status.termsig.to_i
        plain = output.dup.force_encoding(Encoding::UTF_8).scrub
          .gsub(ANSI, "")
          .gsub(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/, "")
        review = "$ #{Shellwords.join(@argv)}\n#{plain}"
        review << "\n" unless review.end_with?("\n")
        review << "[exit #{exit_status}]\n"
        Hive::AtomicFile.write(@cast_path, cast, mode: 0o600)
        Hive::AtomicFile.write(@review_path, review, mode: 0o600)
        {
          "exit_status" => exit_status,
          "representations" => [
            representation("original", "application/x-asciinema+json", @cast_path),
            representation("review", "text/plain", @review_path)
          ]
        }
      end

      def representation(role, media_type, path)
        {
          "role" => role, "media_type" => media_type, "path" => path,
          "sha256" => Digest::SHA256.file(path).hexdigest, "bytes" => File.size(path)
        }
      end

      class << self
        def run_worker!
          request = JSON.parse($stdin.readline)
          recorder = new(
            argv: request.fetch("argv"), cwd: request.fetch("cwd"),
            cast_path: request.fetch("cast_path"), review_path: request.fetch("review_path"),
            environment: request.fetch("environment"),
            timeout_seconds: request.fetch("timeout_seconds"),
            width: request.fetch("width"), height: request.fetch("height")
          )
          recorder.send(:validate!)
          $stdout.write(JSON.generate(recorder.send(:record_direct!)))
        end
      end
    end
  end
end

Hive::Artifacts::TerminalRecorder.run_worker! if
  __FILE__ == $PROGRAM_NAME && ARGV == [ "--worker" ]
