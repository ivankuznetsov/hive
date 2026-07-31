require "digest"
require "open3"
require "rbconfig"
require "hive/attempts/process_identity"
require "hive/attempts/store"
require "hive/errors"
require "hive/modules/migration/candidate_execution_sandbox"
require "hive/modules/migration/qualification_process_failure"
require "hive/modules/migration/qualification_process_custody"

module Hive
  module Modules
    module Migration
      # Trusted host controller for one exact candidate scenario process.
      # Candidate output is never interpreted here; this owner provides a
      # closed environment, physical network isolation for deterministic runs,
      # bounded stream evidence, timeout handling, and PID-namespace teardown.
      class QualificationScenarioProcess
        OUTPUT_LIMIT = 64 * 1024
        READ_JOIN_TIMEOUT_SEC = 1
        TERM_GRACE_SEC = 2
        KILL_GRACE_SEC = 0.2
        POLL_INTERVAL_SEC = 0.02
        Result = Data.define(
          :status, :exit_status, :signal, :timed_out,
          :network_isolated, :stdout, :stderr,
          :duration_seconds, :executable_sha256,
          :ruby_sha256, :attempt_count, :custody_count,
          :sandbox_profile_sha256, :source_inventory_sha256,
          :installed_inventory_sha256, :teardown
        )

        class ExecutionState
          attr_accessor(
            :cleanup, :duration_seconds, :launch, :phase, :status,
            :stderr, :stdout, :timed_out, :waiter
          )

          def initialize
            @cleanup = nil
            @duration_seconds = 0.0
            @launch = nil
            @phase = nil
            @status = nil
            @stderr = nil
            @stdout = nil
            @timed_out = false
            @waiter = nil
          end

          def spawned? = !waiter.nil?
        end
        private_constant :ExecutionState

        class IdentityUnavailable < Hive::ConfigError; end
        class IdentityChanged < Hive::ConfigError; end
        class TerminationUnconfirmed < Hive::ConfigError; end
        class CaptureUnconfirmed < Hive::ConfigError; end
        private_constant(
          :IdentityUnavailable,
          :IdentityChanged,
          :TerminationUnconfirmed,
          :CaptureUnconfirmed
        )

        def initialize(
          output_limit: OUTPUT_LIMIT,
          sandbox: CandidateExecutionSandbox.new,
          process_identity:
            Hive::Attempts::ProcessIdentity.new,
          monotonic: lambda {
            Process.clock_gettime(Process::CLOCK_MONOTONIC)
          }
        )
          @output_limit = Integer(output_limit)
          unless @output_limit.positive?
            raise Hive::ConfigError,
                  "patrol qualification output limit is malformed"
          end
          @sandbox = sandbox
          @process_identity = process_identity
          @monotonic = monotonic
        rescue ArgumentError, TypeError
          raise Hive::ConfigError,
                "patrol qualification output limit is malformed"
        end

        def call(
          executable:, argv:, workspace:, source_root:,
          installed_root:, case_root:, request_ref:, scenario_ref:,
          timeout_seconds:, network:, credentials:, hive_home:
        )
          timeout = Float(timeout_seconds)
          unless timeout.positive? && timeout <= 3_600
            raise Hive::ConfigError,
                  "patrol qualification timeout is malformed"
          end
          executable_sha256 =
            Digest::SHA256.file(executable).hexdigest
          ruby_sha256 =
            Digest::SHA256.file(RbConfig.ruby).hexdigest
          started = @monotonic.call
          state = ExecutionState.new
          launch = nil
          process = nil
          process_error = nil
          begin
            @sandbox.call(
              executable: executable,
              argv: argv,
              workspace: workspace,
              source_root: source_root,
              installed_root: installed_root,
              case_root: case_root,
              request_ref: request_ref,
              scenario_ref: scenario_ref,
              network: network,
              credentials: credentials,
              hive_home: hive_home
            ) do |prepared|
              launch = prepared
              state.launch = prepared
              begin
                process = execute(
                  prepared.command,
                  environment: prepared.environment,
                  cwd: prepared.host_cwd,
                  timeout: timeout,
                  state: state
                )
              rescue StandardError => error
                process_error = error
                raise
              end
              state.phase = "sandbox_finalize"
            end
          rescue StandardError => error
            if state.spawned? && !error.equal?(process_error)
              state.phase = "sandbox_finalize"
            end
            raise
          end
          state.phase = "target_verify"
          duration = @monotonic.call - started
          unless
            Digest::SHA256.file(executable).hexdigest ==
              executable_sha256
            raise Hive::ConfigError,
                  "patrol qualification executable changed during execution"
          end
          state.phase = "custody_verify"
          teardown =
            begin
              teardown_attempts!(
                attempts_root: launch.attempts_root,
                custody_root: launch.custody_root,
                require_terminal:
                  process.fetch(:status).success? &&
                    !process.fetch(:timed_out)
              )
            rescue StandardError
              state.cleanup = cleanup(
                status: "failed",
                live_processes: nil
              )
              raise
            end
          state.cleanup = teardown
          passed =
            process.fetch(:status).success? &&
              !process.fetch(:timed_out) &&
              teardown.fetch("status") == "passed"
          state.phase = "result_finalize"
          Result.new(
            status: passed ? "passed" : "failed",
            exit_status: process.fetch(:status).exitstatus,
            signal: process.fetch(:status).termsig,
            timed_out: process.fetch(:timed_out),
            network_isolated: launch.network_isolated,
            stdout: process.fetch(:stdout),
            stderr: process.fetch(:stderr),
            duration_seconds: duration,
            executable_sha256: executable_sha256.freeze,
            ruby_sha256: ruby_sha256.freeze,
            attempt_count: teardown.fetch("attempt_count"),
            custody_count: teardown.fetch("custody_count"),
            sandbox_profile_sha256:
              launch.profile_sha256,
            source_inventory_sha256:
              launch.source_inventory.digest,
            installed_inventory_sha256:
              launch.installed_inventory.digest,
            teardown: teardown
          ).freeze
        rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP,
               IOError, SystemCallError => error
          if state&.spawned?
            raise post_spawn_failure(
              state,
              error,
              started: started,
              executable_sha256: executable_sha256,
              ruby_sha256: ruby_sha256
            ), cause: error
          end
          raise Hive::ConfigError,
                "patrol qualification process is unavailable: " \
                "#{error.class}"
        rescue StandardError => error
          raise error unless state&.spawned?

          raise post_spawn_failure(
            state,
            error,
            started: started,
            executable_sha256: executable_sha256,
            ruby_sha256: ruby_sha256
          ), cause: error
        end

        private

        def execute(command, environment:, cwd:, timeout:, state:)
          stdin = stdout = stderr = waiter = nil
          out_reader = err_reader = nil
          stdin, stdout, stderr, waiter = Open3.popen3(
            environment,
            *command,
            chdir: cwd,
            pgroup: true,
            unsetenv_others: true
          )
          state.waiter = waiter
          state.phase = "identity"
          stdin.close
          out_reader = capture_stream(stdout)
          err_reader = capture_stream(stderr)
          root_identity =
            await_process_identity(waiter.pid)
          state.phase = "wait"
          status = waiter.join(timeout)&.value
          unless status
            state.timed_out = true
            state.phase = "terminate"
            terminate_foreground!(
              waiter,
              root_identity
            )
            status = waiter.value
          end
          state.status = status
          state.phase = "capture"
          state.stdout = finish_capture(out_reader, stdout)
          state.stderr = finish_capture(err_reader, stderr)
          {
            status: status,
            timed_out: state.timed_out,
            stdout: state.stdout,
            stderr: state.stderr
          }.freeze
        rescue StandardError
          settle_failed_execution!(
            state,
            stdout: stdout,
            stderr: stderr,
            out_reader: out_reader,
            err_reader: err_reader
          )
          raise
        ensure
          stdin&.close unless stdin&.closed?
          stdout&.close unless stdout&.closed?
          stderr&.close unless stderr&.closed?
        end

        def capture_stream(io)
          Thread.new do
            digest = Digest::SHA256.new
            bytes = 0
            while (chunk = io.read(16 * 1024))
              bytes += chunk.bytesize
              digest << chunk
            end
            {
              "bytes" => bytes,
              "sha256" => digest.hexdigest,
              "truncated" => bytes > @output_limit
            }.freeze
          rescue IOError, SystemCallError
            {
              "bytes" => bytes || 0,
              "sha256" => (digest || Digest::SHA256.new).hexdigest,
              "truncated" => true
            }.freeze
          ensure
            io.close unless io.closed?
          end.tap do |thread|
            thread.report_on_exception = false
          end
        end

        def finish_capture(thread, io)
          unless thread.join(READ_JOIN_TIMEOUT_SEC)
            io.close unless io.closed?
            thread.join(READ_JOIN_TIMEOUT_SEC)
          end
          if thread.alive?
            raise CaptureUnconfirmed,
                  "patrol qualification stream capture did not terminate"
          end
          thread.value
        end

        def terminate_foreground!(waiter, identity)
          unless
            @process_identity.status(identity.to_h) ==
              :matching &&
              identity.process_group_id == waiter.pid
            raise IdentityChanged,
                  "patrol qualification process identity changed"
          end
          signal_group("TERM", waiter.pid)
          return if waiter.join(TERM_GRACE_SEC)

          unless
            @process_identity.status(identity.to_h) ==
              :matching
            raise IdentityChanged,
                  "patrol qualification process identity changed"
          end
          signal_group("KILL", waiter.pid)
          unless waiter.join(KILL_GRACE_SEC)
            raise TerminationUnconfirmed,
                  "patrol qualification process did not terminate"
          end
        end

        def signal_group(signal, pid)
          Process.kill(signal, -Integer(pid))
        rescue Errno::ESRCH
          nil
        end

        def teardown_attempts!(
          attempts_root:, custody_root:, require_terminal:
        )
          custody =
            QualificationProcessCustody.read_all(
              root: custody_root
            )
          store = attempt_store(attempts_root)
          scan = store&.scan
          if scan && !scan.invalid_records.empty?
            raise Hive::ConfigError,
                  "patrol qualification attempt custody is unreadable"
          end
          records = scan ? scan.records : []
          records_by_id =
            records.to_h { |record| [ record.attempt_id, record ] }
          custody.each do |attempt_id, sidecar|
            record = records_by_id[attempt_id]
            if record&.wrapper &&
               record.wrapper != sidecar.fetch("wrapper")
              raise Hive::ConfigError,
                    "patrol qualification wrapper custody changed"
            end
          end
          unbound =
            custody.keys - records_by_id.keys
          unless unbound.empty?
            raise Hive::ConfigError,
                  "patrol qualification wrapper custody is unbound"
          end
          records.each do |record|
            sidecar = custody[record.attempt_id]
            unless sidecar
              raise Hive::ConfigError,
                    "patrol qualification wrapper custody is missing"
            end
            if require_terminal && !record.final?
              raise Hive::ConfigError,
                    "patrol qualification attempt did not terminate"
            end
          end
          {
            "status" => "passed",
            "attempt_count" => records.length,
            "custody_count" => custody.length,
            "live_processes" => 0,
            "kill_authority" => "host_pid_namespace"
          }.freeze
        end

        def attempt_store(root)
          return nil unless
            File.exist?(root) || File.symlink?(root)

          stat = File.lstat(root)
          unless
            stat.directory? &&
              !stat.symlink? &&
              stat.uid == Process.euid &&
              (stat.mode & 0o077).zero?
            raise Hive::ConfigError,
                  "patrol qualification attempt store is unsafe"
          end
          Hive::Attempts::Store.new(
            root: root,
            create_directories: false
          )
        end

        def await_process_identity(pid)
          deadline = @monotonic.call + 1
          loop do
            snapshot = @process_identity.capture(pid)
            return snapshot if snapshot
            break if @monotonic.call >= deadline

            sleep POLL_INTERVAL_SEC
          end
          raise IdentityUnavailable,
                "patrol qualification process identity is unavailable"
        end

        def settle_failed_execution!(
          state, stdout:, stderr:, out_reader:, err_reader:
        )
          reaped = reap_owned_group(state.waiter)
          state.status ||=
            state.waiter.value unless state.waiter.alive?
          state.stdout ||=
            recover_capture(out_reader, stdout)
          state.stderr ||=
            recover_capture(err_reader, stderr)
          state.cleanup = cleanup(
            status: reaped ? "unverified" : "failed",
            live_processes: nil
          )
        rescue StandardError
          state.cleanup = cleanup(
            status: "unverified",
            live_processes: nil
          )
        end

        def reap_owned_group(waiter)
          was_alive = waiter.alive?
          if was_alive
            signal_group("TERM", waiter.pid)
            unless waiter.join(TERM_GRACE_SEC)
              signal_group("KILL", waiter.pid)
              waiter.join(KILL_GRACE_SEC)
            end
          end
          return false if waiter.alive?

          if was_alive && !process_group_absent?(waiter.pid)
            signal_group("KILL", waiter.pid)
            deadline = @monotonic.call + KILL_GRACE_SEC
            until process_group_absent?(waiter.pid)
              return false if @monotonic.call >= deadline

              sleep POLL_INTERVAL_SEC
            end
          end
          process_group_absent?(waiter.pid)
        rescue SystemCallError
          false
        end

        def process_group_absent?(pid)
          Process.kill(0, -Integer(pid))
          false
        rescue Errno::ESRCH
          true
        rescue Errno::EPERM
          false
        end

        def recover_capture(thread, io)
          return nil unless thread && io

          unless thread.join(READ_JOIN_TIMEOUT_SEC)
            io.close unless io.closed?
            thread.join(READ_JOIN_TIMEOUT_SEC)
          end
          if thread.alive?
            thread.kill
            thread.join(READ_JOIN_TIMEOUT_SEC)
            return nil
          end

          thread.value
        rescue StandardError
          nil
        end

        def post_spawn_failure(
          state, error, started:, executable_sha256:, ruby_sha256:
        )
          state.duration_seconds =
            safe_duration(started)
          status = state.status
          process_state =
            if status&.exited?
              "exited"
            elsif status&.signaled?
              "signaled"
            else
              "unverified"
            end
          FailureEvidence.build(
            phase: state.phase,
            reason: failure_reason(state.phase, error),
            process_state: process_state,
            exit_status:
              process_state == "exited" ? status.exitstatus : nil,
            signal:
              process_state == "signaled" ? status.termsig : nil,
            timed_out: state.timed_out,
            stdout: state.stdout,
            stderr: state.stderr,
            duration_seconds: state.duration_seconds,
            network_isolated: state.launch.network_isolated,
            executable_sha256: executable_sha256,
            ruby_sha256: ruby_sha256,
            sandbox_profile_sha256:
              state.launch.profile_sha256,
            source_inventory_sha256:
              state.launch.source_inventory.digest,
            installed_inventory_sha256:
              state.launch.installed_inventory.digest,
            cleanup: failure_cleanup(state.cleanup)
          ).then do |evidence|
            PostSpawnFailure.new(evidence: evidence)
          end
        end

        def failure_reason(phase, error)
          return "identity_unavailable" if
            error.is_a?(IdentityUnavailable)
          return "identity_changed" if
            error.is_a?(IdentityChanged)
          return "termination_unconfirmed" if
            error.is_a?(TerminationUnconfirmed)
          return "capture_unconfirmed" if
            error.is_a?(CaptureUnconfirmed)
          return "target_changed" if
            phase == "target_verify" ||
              error.is_a?(CandidateExecutionSandbox::TargetChanged)
          return "custody_unverified" if phase == "custody_verify"
          return "io_failure" if
            error.is_a?(IOError) ||
              error.is_a?(SystemCallError)

          "controller_failure"
        end

        def failure_cleanup(value)
          return cleanup(
            status: "unverified",
            live_processes: nil
          ) unless value.is_a?(Hash)

          status = value["status"]
          live = value["live_processes"]
          if status == "passed" && live == 0
            cleanup(status: "passed", live_processes: 0)
          elsif status == "failed"
            cleanup(status: "failed", live_processes: nil)
          else
            cleanup(status: "unverified", live_processes: nil)
          end
        end

        def cleanup(status:, live_processes:)
          {
            "status" => status,
            "live_processes" => live_processes,
            "kill_authority" => "host_pid_namespace"
          }.freeze
        end

        def safe_duration(started)
          duration = Float(@monotonic.call) - Float(started)
          return 0.0 unless duration.finite?

          [ [ duration, 0.0 ].max, 3_600.0 ].min
        rescue ArgumentError, TypeError
          0.0
        end
      end
    end
  end
end
