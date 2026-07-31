require "digest"
require "open3"
require "rbconfig"
require "hive/attempts/process_identity"
require "hive/attempts/store"
require "hive/errors"
require "hive/modules/migration/candidate_execution_sandbox"
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
          launch = nil
          process = nil
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
            process = execute(
              prepared.command,
              environment: prepared.environment,
              cwd: prepared.host_cwd,
              timeout: timeout
            )
          end
          duration = @monotonic.call - started
          unless
            Digest::SHA256.file(executable).hexdigest ==
              executable_sha256
            raise Hive::ConfigError,
                  "patrol qualification executable changed during execution"
          end
          teardown = teardown_attempts!(
            attempts_root: launch.attempts_root,
            custody_root: launch.custody_root,
            require_terminal:
              process.fetch(:status).success? &&
                !process.fetch(:timed_out)
          )
          passed =
            process.fetch(:status).success? &&
              !process.fetch(:timed_out) &&
              teardown.fetch("status") == "passed"
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
          raise Hive::ConfigError,
                "patrol qualification process is unavailable: " \
                "#{error.class}"
        end

        private

        def execute(command, environment:, cwd:, timeout:)
          stdin = stdout = stderr = waiter = nil
          out_reader = err_reader = nil
          timed_out = false
          stdin, stdout, stderr, waiter = Open3.popen3(
            environment,
            *command,
            chdir: cwd,
            pgroup: true,
            unsetenv_others: true
          )
          stdin.close
          root_identity =
            await_process_identity(waiter.pid)
          out_reader = capture_stream(stdout)
          err_reader = capture_stream(stderr)
          status = waiter.join(timeout)&.value
          unless status
            timed_out = true
            terminate_foreground!(
              waiter,
              root_identity
            )
            status = waiter.value
          end
          {
            status: status,
            timed_out: timed_out,
            stdout: finish_capture(out_reader, stdout),
            stderr: finish_capture(err_reader, stderr)
          }.freeze
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
          unless thread.stop?
            raise Hive::ConfigError,
                  "patrol qualification stream capture did not terminate"
          end
          thread.value
        end

        def terminate_foreground!(waiter, identity)
          unless
            @process_identity.status(identity.to_h) ==
              :matching &&
              identity.process_group_id == waiter.pid
            raise Hive::ConfigError,
                  "patrol qualification process identity changed"
          end
          signal_group("TERM", waiter.pid)
          return if waiter.join(TERM_GRACE_SEC)

          unless
            @process_identity.status(identity.to_h) ==
              :matching
            raise Hive::ConfigError,
                  "patrol qualification process identity changed"
          end
          signal_group("KILL", waiter.pid)
          unless waiter.join(KILL_GRACE_SEC)
            raise Hive::ConfigError,
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
          raise Hive::ConfigError,
                "patrol qualification process identity is unavailable"
        end
      end
    end
  end
end
