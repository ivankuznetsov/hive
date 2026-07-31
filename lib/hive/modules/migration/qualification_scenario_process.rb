require "digest"
require "fileutils"
require "open3"
require "rbconfig"
require "hive/attempts/process_identity"
require "hive/attempts/store"
require "hive/errors"
require "hive/modules/migration/qualification_process_custody"

module Hive
  module Modules
    module Migration
      # Trusted host controller for one exact candidate scenario process.
      # Candidate output is never interpreted here; this owner provides a
      # closed environment, physical network isolation for deterministic runs,
      # bounded stream evidence, timeout handling, and attempt-aware teardown.
      class QualificationScenarioProcess
        OUTPUT_LIMIT = 64 * 1024
        READ_JOIN_TIMEOUT_SEC = 1
        TERM_GRACE_SEC = 2
        KILL_GRACE_SEC = 0.2
        POLL_INTERVAL_SEC = 0.02
        BWRAP = "/usr/bin/bwrap".freeze
        CREDENTIALS = %w[
          GITHUB_TOKEN OPENROUTER_API_KEY
        ].freeze

        Result = Data.define(
          :status, :exit_status, :signal, :timed_out,
          :network_isolated, :stdout, :stderr,
          :duration_seconds, :executable_sha256,
          :ruby_sha256, :attempt_count, :custody_count,
          :teardown
        )

        def initialize(
          output_limit: OUTPUT_LIMIT,
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
          @process_identity = process_identity
          @monotonic = monotonic
        rescue ArgumentError, TypeError
          raise Hive::ConfigError,
                "patrol qualification output limit is malformed"
        end

        def call(
          executable:, argv:, workspace:, installed_root:,
          timeout_seconds:, network:, credentials:, hive_home: nil
        )
          root = validate_directory(
            workspace,
            label: "workspace"
          )
          installed = validate_directory(
            installed_root,
            label: "installed target",
            within: root
          )
          target = validate_executable(executable, root)
          arguments = validate_argv(argv)
          timeout = Float(timeout_seconds)
          unless timeout.positive? && timeout <= 3_600
            raise Hive::ConfigError,
                  "patrol qualification timeout is malformed"
          end
          network = validate_network(network)
          credentials = validate_credentials(
            credentials,
            network: network
          )
          hive_home, scenario_root =
            validate_hive_home(hive_home, root)
          runtime = prepare_runtime(scenario_root)
          environment = closed_environment(
            root: root,
            installed: installed,
            executable: target,
            runtime: runtime,
            hive_home: hive_home,
            credentials: credentials
          )
          command = execution_command(
            executable: target,
            argv: arguments,
            workspace: root,
            network: network
          )
          executable_sha256 =
            Digest::SHA256.file(target).hexdigest
          ruby_sha256 =
            Digest::SHA256.file(RbConfig.ruby).hexdigest
          started = @monotonic.call
          process = execute(
            command,
            environment: environment,
            cwd: root,
            timeout: timeout
          )
          duration = @monotonic.call - started
          unless
            Digest::SHA256.file(target).hexdigest ==
              executable_sha256
            raise Hive::ConfigError,
                  "patrol qualification executable changed during execution"
          end
          teardown = teardown_attempts!(
            attempts_root: File.join(
              hive_home,
              "attempts",
              "v2"
            ),
            custody_root: runtime.fetch(:custody),
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
            network_isolated: !network,
            stdout: process.fetch(:stdout),
            stderr: process.fetch(:stderr),
            duration_seconds: duration,
            executable_sha256: executable_sha256.freeze,
            ruby_sha256: ruby_sha256.freeze,
            attempt_count: teardown.fetch("attempt_count"),
            custody_count: teardown.fetch("custody_count"),
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
            terminate_identity!(
              sidecar.fetch("wrapper")
            )
          end
          records = store ? store.scan.records : []
          records_by_id =
            records.to_h { |record| [ record.attempt_id, record ] }
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
            verify_absent!(
              sidecar.fetch("wrapper"),
              label: "wrapper"
            )
            cleanup_worker!(
              wrapper: sidecar.fetch("wrapper"),
              worker: record.worker
            )
            if require_terminal && !record.final?
              raise Hive::ConfigError,
                    "patrol qualification attempt did not terminate"
            end
          end
          {
            "status" => "passed",
            "attempt_count" => records.length,
            "custody_count" => custody.length,
            "live_processes" => 0
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

        def terminate_identity!(identity)
          state = @process_identity.status(identity)
          return if state == :missing
          unless state == :matching
            raise Hive::ConfigError,
                  "patrol qualification process custody changed"
          end
          pid = identity.fetch("pid")
          Process.kill("TERM", pid)
          wait_for_identity(identity, TERM_GRACE_SEC)
          if @process_identity.status(identity) == :matching
            Process.kill("KILL", pid)
            wait_for_identity(identity, KILL_GRACE_SEC)
          end
          verify_absent!(identity, label: "wrapper")
        rescue Errno::ESRCH
          nil
        end

        def cleanup_worker!(wrapper:, worker:)
          return if worker.nil?

          state = @process_identity.status(worker)
          return if state == :missing
          unless state == :matching
            raise Hive::ConfigError,
                  "patrol qualification worker custody changed"
          end
          outcome =
            @process_identity.terminate_orphan_group(
              wrapper: wrapper,
              worker: worker,
              grace_sec: TERM_GRACE_SEC
            )
          unless %i[absent terminated].include?(outcome)
            raise Hive::ConfigError,
                  "patrol qualification worker did not terminate"
          end
          verify_absent!(worker, label: "worker")
        end

        def verify_absent!(identity, label:)
          return if @process_identity.status(identity) == :missing

          raise Hive::ConfigError,
                "patrol qualification #{label} process remains live"
        end

        def wait_for_identity(identity, timeout)
          deadline = @monotonic.call + timeout
          while
            @process_identity.status(identity) == :matching &&
              @monotonic.call < deadline
            sleep POLL_INTERVAL_SEC
          end
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

        def closed_environment(
          root:, installed:, executable:, runtime:, hive_home:,
          credentials:
        )
          ruby_bin = File.dirname(RbConfig.ruby)
          {
            "HOME" => runtime.fetch(:home),
            "HIVE_HOME" => hive_home,
            "XDG_CONFIG_HOME" =>
              File.join(runtime.fetch(:xdg), "config"),
            "XDG_CACHE_HOME" =>
              File.join(runtime.fetch(:xdg), "cache"),
            "XDG_DATA_HOME" =>
              File.join(runtime.fetch(:xdg), "data"),
            "XDG_STATE_HOME" =>
              File.join(runtime.fetch(:xdg), "state"),
            "TMPDIR" => runtime.fetch(:tmp),
            "LANG" => "C.UTF-8",
            "LC_ALL" => "C.UTF-8",
            "TZ" => "UTC",
            "PATH" => [
              File.join(installed, "bin"),
              File.join(installed, "rubygems-bin"),
              ruby_bin,
              "/usr/bin",
              "/bin"
            ].uniq.join(File::PATH_SEPARATOR),
            "GEM_HOME" => installed,
            "GEM_PATH" => installed,
            "BUNDLE_DISABLE_SHARED_GEMS" => "true",
            "BUNDLE_FROZEN" => "true",
            "GIT_CONFIG_NOSYSTEM" => "1",
            "GIT_CONFIG_GLOBAL" => "/dev/null",
            "GIT_TERMINAL_PROMPT" => "0",
            "HIVE_BIN" => executable,
            "HIVE_INVOKED_BIN" => executable,
            "HIVE_SKIP_LLM_WIKI_SCHEDULER" => "1",
            "HIVE_SKIP_LLM_WIKI_SYSTEMCTL" => "1",
            "HIVE_SKIP_LLM_WIKI_POST_COMMIT" => "1",
            "HIVE_QUALIFICATION_CUSTODY_ROOT" =>
              runtime.fetch(:custody)
          }.merge(credentials).freeze
        end

        def prepare_runtime(root)
          runtime = File.join(root, "runtime")
          values = {
            root: runtime,
            home: File.join(runtime, "home"),
            xdg: File.join(runtime, "xdg"),
            tmp: File.join(runtime, "tmp"),
            custody: File.join(runtime, "custody")
          }
          [
            values.fetch(:root),
            values.fetch(:home),
            values.fetch(:xdg),
            File.join(values.fetch(:xdg), "config"),
            File.join(values.fetch(:xdg), "cache"),
            File.join(values.fetch(:xdg), "data"),
            File.join(values.fetch(:xdg), "state"),
            values.fetch(:tmp),
            values.fetch(:custody)
          ].each do |path|
            FileUtils.mkdir_p(path, mode: 0o700)
            File.chmod(0o700, path)
          end
          values.freeze
        end

        def execution_command(
          executable:, argv:, workspace:, network:
        )
          return [ executable, *argv ].freeze if network

          stat = File.lstat(BWRAP)
          unless stat.file? && !stat.symlink? &&
                 (stat.mode & 0o111).positive?
            raise Hive::ConfigError,
                  "patrol qualification network isolation is unavailable"
          end
          [
            BWRAP,
            "--die-with-parent",
            "--unshare-net",
            "--ro-bind", "/", "/",
            "--bind", workspace, workspace,
            "--dev", "/dev",
            "--proc", "/proc",
            "--chdir", workspace,
            "--",
            executable,
            *argv
          ].freeze
        end

        def validate_directory(value, label:, within: nil)
          path = value.to_s
          unless
            !path.empty? &&
              !path.include?("\0") &&
              path == File.expand_path(path)
            raise Hive::ConfigError,
                  "patrol qualification #{label} is unsafe"
          end
          stat = File.lstat(path)
          unless
            stat.directory? &&
              !stat.symlink? &&
              stat.uid == Process.euid &&
              (stat.mode & 0o077).zero? &&
              File.realpath(path) == path &&
              (
                within.nil? ||
                  path.start_with?(
                    "#{within}#{File::SEPARATOR}"
                  )
              )
            raise Hive::ConfigError,
                  "patrol qualification #{label} is unsafe"
          end
          path.freeze
        end

        def validate_executable(value, workspace)
          path = value.to_s
          unless
            !path.empty? &&
              path == File.expand_path(path) &&
              path.start_with?(
                "#{workspace}#{File::SEPARATOR}"
              )
            raise Hive::ConfigError,
                  "patrol qualification executable is unsafe"
          end
          stat = File.lstat(path)
          unless
            stat.file? &&
              !stat.symlink? &&
              stat.nlink == 1 &&
              stat.uid == Process.euid &&
              (stat.mode & 0o111).positive? &&
              File.realpath(path) == path
            raise Hive::ConfigError,
                  "patrol qualification executable is unsafe"
          end
          path.freeze
        end

        def validate_hive_home(value, workspace)
          path =
            value.nil? ?
              File.join(workspace, "sandbox", "hive-home") :
              value.to_s
          sandbox = File.dirname(path)
          scenario_root = File.dirname(sandbox)
          unless
            !path.empty? &&
              !path.include?("\0") &&
              path == File.expand_path(path) &&
              path.start_with?(
                "#{workspace}#{File::SEPARATOR}"
              ) &&
              File.basename(path) == "hive-home" &&
              File.basename(sandbox) == "sandbox" &&
              (
                scenario_root == workspace ||
                  scenario_root.start_with?(
                    "#{workspace}#{File::SEPARATOR}"
                  )
              )
            raise Hive::ConfigError,
                  "patrol qualification HIVE_HOME is unsafe"
          end
          validate_directory(
            scenario_root,
            label: "scenario root",
            within: scenario_root == workspace ? nil : workspace
          )
          [ path.freeze, scenario_root.freeze ].freeze
        end

        def validate_argv(value)
          unless value.is_a?(Array) &&
                 value.length <= 32 &&
                 value.all? do |item|
                   item.is_a?(String) &&
                     !item.empty? &&
                     item.bytesize <= 4_096 &&
                     !item.include?("\0")
                 end
            raise Hive::ConfigError,
                  "patrol qualification argv is malformed"
          end
          value.map { |item| item.dup.freeze }.freeze
        end

        def validate_network(value)
          unless value == true || value == false
            raise Hive::ConfigError,
                  "patrol qualification network policy is malformed"
          end
          value
        end

        def validate_credentials(value, network:)
          unless
            value.is_a?(Hash) &&
              value.keys.all? do |key|
                key.is_a?(String) &&
                  CREDENTIALS.include?(key)
              end &&
              value.values.all? do |secret|
                secret.is_a?(String) &&
                  !secret.empty? &&
                  secret.bytesize <= 16 * 1024 &&
                  !secret.include?("\0")
              end &&
              (network || value.empty?)
            raise Hive::ConfigError,
                  "patrol qualification credentials are malformed"
          end
          value.to_h do |key, secret|
            [ key.dup.freeze, secret.dup.freeze ]
          end.freeze
        end
      end
    end
  end
end
