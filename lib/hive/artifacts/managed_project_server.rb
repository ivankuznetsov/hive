require "net/http"
require "uri"
require "hive"
require "hive/artifacts/project_command_sandbox"
require "hive/process_kill"

module Hive
  module Artifacts
    # One attempt-owned application server for non-Hive browser evidence. The
    # producer selects a repository executable, while Hive owns isolation,
    # readiness, credentials, the exact port, output bounds, and teardown.
    class ManagedProjectServer
      START_TIMEOUT_SECONDS = 90
      STOP_TIMEOUT_SECONDS = 5
      POLL_SECONDS = 0.05
      MAX_OUTPUT_BYTES = 64 * 1024
      MAX_ARGV_ITEMS = 64
      MAX_ARGV_BYTES = 64 * 1024

      class ServerError < Hive::Error; end

      attr_reader :receipt

      def initialize(source_root:, port:, environment: ENV, sandbox_binary: nil,
                     spawner: nil, waiter: nil, process_killer: nil,
                     start_time_resolver: nil, readiness_probe: nil,
                     clock: nil, sleeper: nil)
        @source_root = File.realpath(source_root)
        @port = Integer(port)
        raise ArgumentError, "port is outside 1..65535" unless @port.between?(1, 65_535)

        @environment = environment.to_h
        @sandbox = Hive::Artifacts::ProjectCommandSandbox.new(
          source_root: @source_root, environment: @environment,
          sandbox_binary: sandbox_binary, share_network: true,
          extra_environment: { "PORT" => @port.to_s }
        )
        @spawner = spawner || lambda do |environment, *argv, **options|
          Process.spawn(environment, *argv, **options)
        end
        @waiter = waiter || ->(pid) { Process.waitpid2(pid, Process::WNOHANG) }
        @process_killer = process_killer || Hive::ProcessKill.method(:terminate_process_group)
        @start_time_resolver = start_time_resolver || Hive::ProcessKill.method(:process_start_time)
        @readiness_probe = readiness_probe || method(:ready?)
        @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @sleeper = sleeper || ->(seconds) { sleep(seconds) }
        @output = +"".b
      rescue Hive::Artifacts::ProjectCommandSandbox::SandboxError,
             Errno::ENOENT, Errno::EACCES, ArgumentError, TypeError => e
        raise ServerError, "project evidence server is unavailable: #{e.message}"
      end

      def start!(argv)
        raise ServerError, "project evidence server is already running" if @pid

        command = validate_command!(argv)
        @output_reader, output_writer = IO.pipe
        @pid = @spawner.call(
          {}, *@sandbox.command_argv(command),
          chdir: @source_root, pgroup: true, unsetenv_others: true,
          in: File::NULL, out: output_writer, err: output_writer
        )
        output_writer.close
        output_writer = nil
        @start_time = @start_time_resolver.call(@pid).to_s
        raise ServerError, "project evidence server process identity is unavailable" if @start_time.empty?

        start_output_drain
        wait_until_ready!
        @receipt = {
          "driver" => "hive-project-server",
          "status" => "ready",
          "app_port" => @port,
          "app_endpoint" => "http://127.0.0.1:#{@port}"
        }.freeze
      rescue ServerError
        close_after_error
        raise
      rescue Hive::Artifacts::ProjectCommandSandbox::SandboxError,
             SystemCallError, IOError => e
        close_after_error
        raise ServerError, diagnostic("project evidence server could not start: #{e.message}")
      ensure
        output_writer&.close unless output_writer&.closed?
      end

      def close
        cleanup_error = nil
        if @pid
          result = @process_killer.call(
            @pid, recorded_start_time: @start_time,
            grace_seconds: STOP_TIMEOUT_SECONDS
          )
          unless result.killed || result.skipped_reason == "not_alive"
            cleanup_error = ServerError.new(
              "project evidence server teardown was not proven (#{result.skipped_reason})"
            )
          end
          reap
        end
        @output_reader&.close unless @output_reader&.closed?
        @output_thread&.join(1)
        @sandbox.close
        raise cleanup_error if cleanup_error

        true
      rescue Hive::Artifacts::ProjectCommandSandbox::SandboxError => e
        raise ServerError, "project evidence server teardown failed: #{e.message}"
      ensure
        @pid = nil
        @start_time = nil
        @output_reader = nil
        @output_thread = nil
        @receipt = nil
      end

      private

      def validate_command!(argv)
        command = Array(argv).map(&:to_s)
        bytes = command.sum { |part| part.bytesize + 1 }
        unless command.any? && command.length <= MAX_ARGV_ITEMS &&
               command.none?(&:empty?) && bytes <= MAX_ARGV_BYTES
          raise ServerError, "project evidence server command is invalid"
        end
        executable = File.expand_path(command.first, @source_root)
        unless executable.start_with?("#{@source_root}#{File::SEPARATOR}")
          raise ServerError, "project evidence server executable escapes the source root"
        end
        stat = File.lstat(executable)
        real = File.realpath(executable)
        unless stat.file? && !stat.symlink? && File.executable?(executable) &&
               real.start_with?("#{@source_root}#{File::SEPARATOR}")
          raise ServerError, "project evidence server executable is not an executable repository file"
        end

        [ real, *command.drop(1) ]
      rescue Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP
        raise ServerError, "project evidence server executable is unavailable"
      end

      def start_output_drain
        @output_thread = Thread.new do
          while (chunk = @output_reader.read(16 * 1024))
            remaining = MAX_OUTPUT_BYTES - @output.bytesize
            @output << chunk.byteslice(0, remaining) if remaining.positive?
          end
        rescue IOError
          nil
        end
        @output_thread.report_on_exception = false
      end

      def wait_until_ready!
        deadline = @clock.call + START_TIMEOUT_SECONDS
        loop do
          waited = @waiter.call(@pid)
          if waited
            @pid = nil
            raise ServerError,
                  diagnostic("project evidence server exited before readiness " \
                             "(exit=#{waited.last.exitstatus.inspect})")
          end
          return if @readiness_probe.call("http://127.0.0.1:#{@port}/")
          if @clock.call >= deadline
            raise ServerError, diagnostic("project evidence server was not ready within " \
                                          "#{START_TIMEOUT_SECONDS}s")
          end

          @sleeper.call(POLL_SECONDS)
        end
      end

      def ready?(url)
        uri = URI(url)
        response = Net::HTTP.start(
          uri.host, uri.port, open_timeout: 1, read_timeout: 1
        ) { |http| http.get(uri.request_uri) }
        response.code.to_i.between?(100, 499)
      rescue SystemCallError, IOError, Timeout::Error
        false
      end

      def close_after_error
        close
      rescue ServerError
        nil
      end

      def reap
        @waiter.call(@pid)
      rescue Errno::ECHILD
        nil
      end

      def diagnostic(prefix)
        detail = @output.dup.force_encoding(Encoding::UTF_8).scrub.strip
        detail.empty? ? prefix : "#{prefix}: #{detail}".byteslice(0, MAX_OUTPUT_BYTES).to_s.scrub
      end
    end
  end
end
