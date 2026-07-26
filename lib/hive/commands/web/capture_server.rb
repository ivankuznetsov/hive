require "json"
require "net/http"
require "rbconfig"
require "securerandom"
require "time"
require "uri"
require "hive"
require "hive/process_kill"
require "hive/web/capture_runtime"

module Hive
  module Commands
    class Web
      # Internal supervisor used by recorder scripts. It owns exactly one
      # isolated Rails process group and tears it down when its control channel
      # closes. It never installs or mutates the normal Hive web service.
      class CaptureServer
        BOOT_TIMEOUT_SEC = 90
        CONTROL_POLL_SEC = 0.1

        class BootstrapError < Hive::Error; end
        class ReadinessError < Hive::Error; end
        class TeardownError < Hive::Error; end

        def initialize(source_root:, runtime_root:, lifecycle_token:, port: 0,
                       control_io: $stdin, output: $stdout, error: $stderr,
                       environment: ENV, runtime: nil, phase_runner: nil,
                       spawner: nil, readiness_probe: nil,
                       boot_timeout_sec: BOOT_TIMEOUT_SEC)
          @source_root = File.expand_path(source_root)
          @runtime_root = File.expand_path(runtime_root)
          @lifecycle_token = lifecycle_token.to_s
          @requested_port = Integer(port || 0)
          @control_io = control_io
          @output = output
          @error = error
          @environment = environment
          @runtime = runtime || Hive::Web::CaptureRuntime.new(
            source_root: @source_root,
            runtime_root: @runtime_root,
            environment: @environment,
            lifecycle_token: @lifecycle_token,
            cache_root: @environment["HIVE_WEB_CAPTURE_CACHE_ROOT"]
          )
          @phase_runner = phase_runner || method(:run_phase)
          @spawner = spawner || method(:spawn_server)
          @readiness_probe = readiness_probe || method(:ready?)
          @boot_timeout_sec = Float(boot_timeout_sec)
        end

        def call
          bundle = @runtime.prepare!
          port, reservation = @runtime.allocate_port(@requested_port)
          env = @runtime.environment(bundle_path: bundle.bundle_path, port: port)
          run_bootstrap!(env, bundler_executable: bundle.bundler_executable)
          # Revalidate clean source/HEAD after dependency and asset/database
          # bootstrap. A misconfigured build that wrote into the worktree is a
          # contamination failure, never a successful capture server.
          verified = @runtime.prepare!
          unless verified.source_sha == bundle.source_sha
            raise BootstrapError, "source HEAD changed during capture bootstrap"
          end

          reservation.close
          reservation = nil
          pid = @spawner.call(
            server_argv(port, bundler_executable: bundle.bundler_executable),
            env,
            chdir: File.join(@source_root, "web")
          )
          start_time = Hive::ProcessKill.process_start_time(pid)
          raise BootstrapError, "capture server process identity is unavailable" if start_time.to_s.empty?

          @runtime.write_lifecycle!(
            pid: pid,
            process_start_time: start_time,
            process_group: pid,
            port: port,
            source_sha: bundle.source_sha
          )
          wait_until_ready!(pid, port)
          receipt = Hive::Web::CaptureRuntime::Readiness.new(
            lifecycle_id: @lifecycle_token,
            pid: pid,
            process_start_time: start_time,
            process_group: pid,
            port: port,
            readiness_url: "http://127.0.0.1:#{port}/health",
            source_sha: bundle.source_sha,
            cache_key: bundle.cache_key,
            lock_digests: bundle.lock_digests,
            runtime_root: @runtime_root,
            storage_root: env.fetch("HIVE_WEB_STORAGE_DIR"),
            started_at: Time.now.utc.iso8601(6)
          )
          @output.puts(JSON.generate(receipt.to_h))
          @output.flush
          wait_for_shutdown(pid)
          receipt
        ensure
          reservation&.close
          teardown!(pid, start_time) if pid
          if @runtime && (!@runtime.respond_to?(:claimed?) || @runtime.claimed?)
            @runtime.cleanup_runtime!(preserve_diagnostics: false)
          end
        end

        private

        def run_bootstrap!(env, bundler_executable:)
          [
            [ "assets", rails_argv(bundler_executable, "assets:precompile") ],
            [ "database", rails_argv(bundler_executable, "db:prepare") ]
          ].each do |name, argv|
            ok = @phase_runner.call(argv, env, chdir: File.join(@source_root, "web"))
            raise BootstrapError, "capture #{name} bootstrap failed" unless ok
          end
        end

        def server_argv(port, bundler_executable:)
          rails_argv(
            bundler_executable,
            "server", "-b", Hive::Web::CaptureRuntime::BIND, "-p", port.to_s
          )
        end

        def rails_argv(bundler_executable, *args)
          [ RbConfig.ruby, bundler_executable, "exec", "bin/rails", *args ]
        end

        def run_phase(argv, env, chdir:)
          system(
            env,
            *argv,
            chdir: chdir,
            in: File::NULL,
            out: @error,
            err: @error,
            unsetenv_others: true
          )
        end

        def spawn_server(argv, env, chdir:)
          Process.spawn(
            env,
            *argv,
            chdir: chdir,
            pgroup: true,
            in: File::NULL,
            out: @error,
            err: @error,
            unsetenv_others: true
          )
        rescue SystemCallError => e
          raise BootstrapError, "capture server spawn failed: #{e.message}"
        end

        def wait_until_ready!(pid, port)
          deadline = monotonic_now + @boot_timeout_sec
          loop do
            waited = Process.waitpid2(pid, Process::WNOHANG)
            if waited
              raise ReadinessError,
                    "capture server exited before readiness (exit=#{waited.last.exitstatus.inspect})"
            end
            return if @readiness_probe.call("http://127.0.0.1:#{port}/health")
            raise ReadinessError, "capture server was not ready within #{@boot_timeout_sec}s" if
              monotonic_now >= deadline

            sleep CONTROL_POLL_SEC
          end
        end

        def ready?(url)
          uri = URI(url)
          response = Net::HTTP.start(
            uri.host,
            uri.port,
            open_timeout: 1,
            read_timeout: 1
          ) { |http| http.get(uri.request_uri) }
          response.is_a?(Net::HTTPSuccess)
        rescue SystemCallError, IOError, Timeout::Error
          false
        end

        def wait_for_shutdown(pid)
          raise BootstrapError, "capture control channel is required" unless @control_io

          loop do
            return if Process.waitpid2(pid, Process::WNOHANG)

            readable = IO.select([ @control_io ], nil, nil, CONTROL_POLL_SEC)
            next unless readable

            byte = @control_io.read_nonblock(1, exception: false)
            return if byte.nil?
          end
        rescue IOError, Errno::EBADF
          nil
        end

        def teardown!(pid, start_time)
          result = Hive::ProcessKill.terminate_process_group(
            pid,
            recorded_start_time: start_time,
            grace_seconds: Hive::Web::CaptureRuntime::CLEANUP_TIMEOUT_SEC
          )
          Process.waitpid(pid, Process::WNOHANG)
          return if result.killed || result.skipped_reason == "not_alive"

          raise TeardownError,
                "capture server teardown did not prove cleanup (#{result.skipped_reason})"
        rescue Errno::ECHILD
          nil
        end

        def monotonic_now
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
    end
  end
end
