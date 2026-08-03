require "digest"
require "base64"
require "fileutils"
require "fiddle"
require "json"
require "timeout"
require "time"
require "hive"
require "hive/invoked_binary"
require "hive/process_kill"
require "hive/secret_patterns"

module Hive
  module Web
    # Runs a project-owned capture recorder as a bounded, credential-free
    # subprocess. Hive accepts provider artifacts only from its private
    # staging directory and validates every declaration before publication.
    class ProjectCaptureProvider
      REQUEST_SCHEMA = "hive-project-capture-request".freeze
      REQUEST_SCHEMA_VERSION = 1
      RESULT_SCHEMA = "hive-project-capture-result".freeze
      RESULT_SCHEMA_VERSION = 1
      MAX_OUTPUT_BYTES = 256 * 1024
      MAX_DIAGNOSTIC_BYTES = 16 * 1024
      MAX_COMMAND_BYTES = Hive::PROJECT_CAPTURE_PROVIDER_MAX_COMMAND_BYTES
      MAX_EVIDENCE_BYTES = Hive::PROJECT_CAPTURE_PROVIDER_MAX_EVIDENCE_BYTES
      MAX_ARTIFACTS = 32
      MAX_ARTIFACT_BYTES = 256 * 1024 * 1024
      MAX_TOTAL_ARTIFACT_BYTES = 512 * 1024 * 1024
      CUSTODY_TERM_GRACE_SEC = 0.35
      CUSTODY_KILL_GRACE_SEC = 0.35
      CUSTODY_POLL_SEC = 0.01
      SUPERVISOR_RESULT_MAX_BYTES = 512 * 1024
      PR_SET_CHILD_SUBREAPER = 36
      PR_GET_CHILD_SUBREAPER = 37
      MEDIA_FILE = /\A[\w.-]+\.(?:png|jpe?g|gif|webp|webm|mp4)\z/i
      SAFE_AMBIENT_KEYS = %w[PATH LANG LC_ALL LC_CTYPE TZ SSL_CERT_FILE SSL_CERT_DIR].freeze
      CLEANUP = {
        "port" => "released", "processes" => "clean", "runtime" => "cleaned"
      }.freeze

      Result = Data.define(
        :name, :command, :environment_keys, :artifacts, :evidence,
        :cleanup, :diagnostic, :started_at, :finished_at
      )

      class ProviderError < Hive::Error; end

      # TaskCapture's source-attestation Git probes need the same bounded
      # process-tree custody as the configured provider itself. Keep that
      # boundary here so detached helpers cannot outlive either caller.
      def self.capture_command_with_custody(argv:, source_root:, environment:, deadline:,
                                            stdout_consumer: nil)
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        allocate.send(
          :supervise_provider,
          Array(argv),
          request: nil,
          source_root: source_root,
          environment: environment,
          timeout_sec: [ remaining, 0 ].max,
          deadline: deadline,
          stdout_consumer: stdout_consumer
        )
      end

      def initialize(config:, environment: ENV, clock: -> { Time.now.utc })
        @config = config
        @environment = environment.to_h
        @clock = clock
      end

      def call(task:, source_root:, source_sha:, staging_root:, runtime_root:)
        source_root = File.realpath(source_root)
        staging_root = File.realpath(staging_root)
        ensure_private_directory!(staging_root, "provider staging root")
        FileUtils.mkdir_p(runtime_root, mode: 0o700)
        runtime_root = File.realpath(runtime_root)
        ensure_private_directory!(runtime_root, "provider runtime root")
        command = @config.fetch("command").map(&:to_s)
        validate_command_budget!(command)
        executable = provider_executable(source_root, command.fetch(0))
        request = {
          "schema" => REQUEST_SCHEMA,
          "schema_version" => REQUEST_SCHEMA_VERSION,
          "task" => task.to_s,
          "source_root" => source_root,
          "source_sha" => source_sha.to_s,
          "staging_root" => staging_root
        }
        started_at = @clock.call
        stdout, stderr = execute!(
          [ executable, *command.drop(1) ],
          request: request,
          source_root: source_root,
          environment: provider_environment(runtime_root),
          timeout_sec: @config.fetch("timeout_sec", 120)
        )
        reject_secret_shaped_output!(stdout, stderr)
        document = parse_result(stdout)
        validate_result_shape!(document)
        if document.fetch("status") != "captured"
          diagnostic = document["diagnostic"]
          diagnostic = "provider reported failure" if diagnostic.to_s.strip.empty?
          raise ProviderError,
                "project capture provider #{@config.fetch('name')} failed: " \
                "#{bounded_diagnostic(diagnostic)}"
        end
        artifacts = validate_artifacts!(document.fetch("artifacts"), staging_root)
        validate_staging_inventory!(staging_root, artifacts)

        Result.new(
          name: @config.fetch("name"),
          command: command.freeze,
          environment_keys: provider_environment(runtime_root).keys.sort.freeze,
          artifacts: artifacts.freeze,
          evidence: document.fetch("evidence").freeze,
          cleanup: document.fetch("cleanup").freeze,
          diagnostic: document["diagnostic"],
          started_at: started_at,
          finished_at: @clock.call
        )
      rescue KeyError, JSON::GeneratorError, JSON::ParserError, SystemCallError, TypeError => e
        raise ProviderError, bounded_diagnostic(e)
      end

      private

      def provider_executable(source_root, relative)
        candidate = File.expand_path(relative, source_root)
        unless candidate.start_with?("#{source_root}#{File::SEPARATOR}")
          raise ProviderError, "project capture provider executable escapes the source root"
        end
        stat = File.lstat(candidate)
        unless stat.file? && !stat.symlink? && File.executable?(candidate)
          raise ProviderError,
                "project capture provider executable must be a regular executable file: #{relative}"
        end
        real = File.realpath(candidate)
        unless real.start_with?("#{source_root}#{File::SEPARATOR}")
          raise ProviderError, "project capture provider executable escapes the source root"
        end

        real
      rescue Errno::ENOENT, Errno::ENOTDIR
        raise ProviderError, "project capture provider executable is unavailable: #{relative}"
      end

      def validate_command_budget!(command)
        bytes = command.sum { |part| part.bytesize + 1 }
        return if bytes <= MAX_COMMAND_BYTES

        raise ProviderError,
              "project capture provider command argv exceeded #{MAX_COMMAND_BYTES} bytes"
      end

      def provider_environment(runtime_root)
        home = private_dir(runtime_root, "home")
        xdg = private_dir(runtime_root, "xdg")
        tmp = private_dir(runtime_root, "tmp")
        safe = SAFE_AMBIENT_KEYS.each_with_object({}) do |key, allowed|
          value = @environment[key]
          allowed[key] = value if value && !value.empty?
        end
        safe["PATH"] ||= "/usr/local/bin:/usr/bin:/bin"
        safe.merge(
          "HOME" => home,
          "XDG_CONFIG_HOME" => private_dir(xdg, "config"),
          "XDG_CACHE_HOME" => private_dir(xdg, "cache"),
          "XDG_DATA_HOME" => private_dir(xdg, "data"),
          "XDG_STATE_HOME" => private_dir(xdg, "state"),
          "TMPDIR" => tmp
        )
      end

      def private_dir(root, name)
        path = File.join(root, name)
        FileUtils.mkdir_p(path, mode: 0o700)
        FileUtils.chmod(0o700, path)
        path
      end

      def execute!(argv, request:, source_root:, environment:, timeout_sec:)
        result = supervise_provider(
          argv,
          request: request,
          source_root: source_root,
          environment: environment,
          timeout_sec: Integer(timeout_sec)
        )
        raise ProviderError, bounded_diagnostic(result.fetch("internal_error")) if result["internal_error"]
        if result.fetch("cleanup_failed")
          raise ProviderError, "project capture provider descendants could not be terminated"
        end
        raise ProviderError, "project capture provider timed out after #{timeout_sec}s" if result.fetch("timed_out")
        if result.fetch("stdout_overflow")
          raise ProviderError, "project capture provider stdout exceeded #{MAX_OUTPUT_BYTES} bytes"
        end
        if result.fetch("stderr_overflow")
          raise ProviderError, "project capture provider stderr exceeded #{MAX_DIAGNOSTIC_BYTES} bytes"
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
          raise ProviderError, "project capture provider failed (#{exit_detail})#{suffix}"
        end
        if result.fetch("leftover_processes")
          raise ProviderError, "project capture provider left child processes running"
        end

        [ result.fetch("stdout"), result.fetch("stderr") ]
      rescue Errno::ENOENT, Errno::EACCES => e
        raise ProviderError, "project capture provider could not start: #{bounded_diagnostic(e)}"
      end

      def supervise_provider(argv, request:, source_root:, environment:, timeout_sec:,
                             deadline: nil, stdout_consumer: nil)
        reader = writer = result_thread = custody_pid = custody_target = nil
        result = primary_error = custody_error = nil
        begin
          reader, writer = IO.pipe
          custody_pid = Process.fork do
            reader.close
            payload = begin
              Process.setsid
              encode_supervisor_result(
                supervise_provider_in_custody(
                  argv,
                  request: request,
                  source_root: source_root,
                  environment: environment,
                  timeout_sec: timeout_sec,
                  deadline: deadline,
                  stdout_consumer: stdout_consumer
                )
              )
            rescue Exception => e # rubocop:disable Lint/RescueException -- trusted custody root must report before exit!
              { "internal_error" => "#{e.class}: #{e.message}" }
            end
            write_supervisor_result(writer, payload)
          ensure
            writer.close unless writer.closed?
            exit! 0
          end
          writer.close
          custody_target = recorded_process_target!(custody_pid, "custody root")
          result_thread = Thread.new { read_supervisor_result(reader) }
          result_thread.report_on_exception = false
          outer_runtime = deadline ? [ deadline - monotonic_now, 0 ].max : timeout_sec
          outer_limit = outer_runtime + (2 * (CUSTODY_TERM_GRACE_SEC + CUSTODY_KILL_GRACE_SEC)) + 2
          custody_status = wait_for_supervisor_status!(
            custody_target,
            deadline: monotonic_now + outer_limit,
            label: "custody root"
          )
          unless custody_status.success?
            raise ProviderError,
                  "project capture provider custody root failed " \
                  "(#{serialized_exit_detail(custody_status)})"
          end
          raw = begin
            Timeout.timeout(0.5) { result_thread.value }
          rescue Timeout::Error
            raise ProviderError,
                  "project capture provider custody result exceeded its read deadline"
          end
          result = decode_supervisor_result(raw)
        rescue StandardError => e
          primary_error = e
        ensure
          begin
            cleanup_command_custody_tree!(custody_target)
          rescue StandardError => e
            custody_error = e
          end
          reader&.close unless reader&.closed?
          writer&.close unless writer&.closed?
          result_thread&.join(0.1)
        end

        if primary_error && custody_error
          raise ProviderError,
                "#{bounded_diagnostic(primary_error)}; command custody also failed: " \
                "#{bounded_diagnostic(custody_error)}"
        end
        raise primary_error if primary_error
        raise custody_error if custody_error

        result
      end

      # The caller is never made a subreaper and is never scanned for children.
      # This freshly forked custody root owns only the nested supervisor and the
      # command subtree, so even abnormal supervisor death cannot transfer an
      # unrelated caller process into cleanup custody.
      def supervise_provider_in_custody(argv, request:, source_root:, environment:,
                                        timeout_sec:, deadline:, stdout_consumer:)
        reader = writer = result_thread = supervisor_pid = supervisor_target = nil
        parent_was_subreaper = nil
        parent_custody_active = false
        result = primary_error = custody_error = nil
        begin
          parent_was_subreaper = child_subreaper_enabled?
          enable_child_subreaper! unless parent_was_subreaper
          unless supervisor_descendants.empty?
            raise ProviderError,
                  "project capture provider parent has unexpected pre-existing descendants"
          end
          parent_custody_active = true

          reader, writer = IO.pipe
          supervisor_pid = Process.fork do
            reader.close
            payload = begin
              Process.setsid
              enable_child_subreaper!
              supervise_provider_child(
                argv,
                request: request,
                source_root: source_root,
                environment: environment,
                timeout_sec: timeout_sec,
                deadline: deadline,
                stdout_consumer: stdout_consumer
              )
            rescue Exception => e # rubocop:disable Lint/RescueException -- trusted supervisor must report before exit!
              { "internal_error" => "#{e.class}: #{e.message}" }
            end
            write_supervisor_result(writer, payload)
          ensure
            writer.close unless writer.closed?
            exit! 0
          end
          writer.close
          supervisor_target = recorded_process_target!(supervisor_pid, "supervisor")
          result_thread = Thread.new { read_supervisor_result(reader) }
          result_thread.report_on_exception = false
          outer_runtime = deadline ? [ deadline - monotonic_now, 0 ].max : timeout_sec
          outer_limit = outer_runtime + CUSTODY_TERM_GRACE_SEC + CUSTODY_KILL_GRACE_SEC + 1
          supervisor_status = wait_for_supervisor_status!(
            supervisor_target,
            deadline: monotonic_now + outer_limit
          )
          unless supervisor_status.success?
            raise ProviderError,
                  "project capture provider supervisor failed " \
                  "(#{serialized_exit_detail(supervisor_status)})"
          end
          raw = begin
            Timeout.timeout(0.5) { result_thread.value }
          rescue Timeout::Error
            raise ProviderError,
                  "project capture provider supervisor result exceeded its read deadline"
          end
          result = decode_supervisor_result(raw)
        rescue StandardError => e
          primary_error = e
        ensure
          begin
            cleanup_parent_provider_tree!(supervisor_target) if parent_custody_active
          rescue StandardError => e
            custody_error = e
          end
          reader&.close unless reader&.closed?
          writer&.close unless writer&.closed?
          result_thread&.join(0.1)
          if parent_was_subreaper == false && custody_error.nil?
            begin
              disable_child_subreaper!
            rescue StandardError => e
              custody_error = e
            end
          end
        end

        if primary_error && custody_error
          raise ProviderError,
                "#{bounded_diagnostic(primary_error)}; parent provider custody also failed: " \
                "#{bounded_diagnostic(custody_error)}"
        end
        raise primary_error if primary_error
        raise custody_error if custody_error

        result
      end

      def cleanup_command_custody_tree!(custody_target)
        return unless custody_target &&
                      Hive::ProcessKill.captured_process_alive?(custody_target)

        deadline = monotonic_now + CUSTODY_TERM_GRACE_SEC + CUSTODY_KILL_GRACE_SEC
        term_deadline = [ monotonic_now + CUSTODY_TERM_GRACE_SEC, deadline ].min
        owned_targets = command_custody_targets(custody_target)
        signal_targets("TERM", owned_targets)
        remaining = wait_for_command_custody_exit(
          custody_target, owned_targets, deadline: term_deadline, signal: "TERM"
        )
        unless remaining.empty?
          signal_targets("KILL", remaining)
          remaining = wait_for_command_custody_exit(
            custody_target, owned_targets, deadline: deadline, signal: "KILL"
          )
        end
        return if remaining.empty?

        raise ProviderError,
              "project capture provider could not terminate its command custody subtree"
      end

      def wait_for_command_custody_exit(custody_target, owned_targets, deadline:, signal:)
        loop do
          if Hive::ProcessKill.captured_process_alive?(custody_target)
            owned_targets.concat(command_custody_targets(custody_target))
          end
          owned_targets.uniq! { |target| [ target.fetch(:pid), target.fetch(:start_time) ] }
          reap_command_custody_root(custody_target)
          remaining = owned_targets.select do |target|
            Hive::ProcessKill.captured_process_alive?(target)
          end
          return [] if remaining.empty?
          return remaining if monotonic_now >= deadline

          signal_targets(signal, remaining)
          sleep CUSTODY_POLL_SEC
        end
      end

      def command_custody_targets(custody_target)
        targets = confirmed_descendants(custody_target.fetch(:pid))
        if Hive::ProcessKill.captured_process_alive?(custody_target)
          targets << custody_target
        end
        targets.sort_by { |target| [ -target.fetch(:depth), target.fetch(:pid) ] }
      end

      def reap_command_custody_root(custody_target)
        Process.waitpid(custody_target.fetch(:pid), Process::WNOHANG)
      rescue Errno::ECHILD
        nil
      end

      def recorded_process_target!(pid, label)
        start_time = Hive::ProcessKill.process_start_time(pid)
        if start_time.to_s.empty?
          raise ProviderError, "project capture provider #{label} identity is unavailable"
        end

        { pid: pid, start_time: start_time, depth: 0 }
      end

      def wait_for_supervisor_status!(target, deadline:, label: "supervisor")
        pid = target.fetch(:pid)
        loop do
          waited = Process.waitpid2(pid, Process::WNOHANG)
          if waited
            unless waited.fetch(0) == pid
              raise ProviderError, "project capture provider #{label} identity changed"
            end

            return waited.fetch(1)
          end
          if monotonic_now >= deadline
            raise ProviderError,
                  "project capture provider #{label} exceeded its custody deadline"
          end

          live_start_time = Hive::ProcessKill.process_start_time(pid)
          unless live_start_time.to_s == target.fetch(:start_time).to_s
            waited = Process.waitpid2(pid, Process::WNOHANG)
            return waited.fetch(1) if waited&.fetch(0) == pid

            raise ProviderError, "project capture provider #{label} identity changed"
          end
          sleep CUSTODY_POLL_SEC
        end
      rescue Errno::ECHILD
        raise ProviderError,
              "project capture provider #{label} exit status custody was lost"
      end

      def cleanup_parent_provider_tree!(supervisor_target)
        deadline = monotonic_now + CUSTODY_TERM_GRACE_SEC + CUSTODY_KILL_GRACE_SEC
        term_deadline = [ monotonic_now + CUSTODY_TERM_GRACE_SEC, deadline ].min
        remaining = parent_provider_targets(supervisor_target)
        signal_targets("TERM", remaining)
        remaining = wait_for_parent_provider_exit(
          supervisor_target, deadline: term_deadline, signal: "TERM"
        )
        unless remaining.empty?
          signal_targets("KILL", remaining)
          remaining = wait_for_parent_provider_exit(
            supervisor_target, deadline: deadline, signal: "KILL"
          )
        end
        return if remaining.empty?

        raise ProviderError,
              "project capture provider parent could not terminate and verify every descendant"
      end

      def wait_for_parent_provider_exit(supervisor_target, deadline:, signal:)
        loop do
          targets = parent_provider_targets(supervisor_target)
          reap_parent_provider_children(targets)
          targets = parent_provider_targets(supervisor_target)
          return [] if targets.empty?
          return targets if monotonic_now >= deadline

          signal_targets(signal, targets)
          sleep CUSTODY_POLL_SEC
        end
      end

      def parent_provider_targets(supervisor_target)
        targets = supervisor_descendants
        if supervisor_target && Hive::ProcessKill.captured_process_alive?(supervisor_target)
          targets << supervisor_target
        end
        targets.uniq { |target| [ target.fetch(:pid), target.fetch(:start_time) ] }
               .sort_by { |target| [ -target.fetch(:depth), target.fetch(:pid) ] }
      end

      def reap_parent_provider_children(targets)
        targets.each do |target|
          Process.waitpid(target.fetch(:pid), Process::WNOHANG)
        rescue Errno::ECHILD
          nil
        end
      end

      def serialized_exit_detail(status)
        return "signal #{status.termsig.inspect}" if status.signaled?

        "exit #{status.exitstatus.inspect}"
      end

      def supervise_provider_child(argv, request:, source_root:, environment:,
                                    timeout_sec:, deadline: nil, stdout_consumer: nil)
        stdin_reader, stdin_writer = IO.pipe
        stdout_reader, stdout_writer = IO.pipe
        stderr_reader, stderr_writer = IO.pipe
        unless supervisor_descendants.empty?
          raise ProviderError, "provider supervisor has unexpected pre-existing descendants"
        end
        executable = argv.fetch(0)
        provider_pid = Process.spawn(
          environment, [ executable, executable ], *argv.drop(1),
          chdir: source_root,
          in: stdin_reader,
          out: stdout_writer,
          err: stderr_writer,
          pgroup: true,
          unsetenv_others: true
        )
        [ stdin_reader, stdout_writer, stderr_writer ].each(&:close)
        stdin_writer.write("#{JSON.generate(request)}\n") if request
        stdin_writer.close
        streams = {
          stdout_reader => {
            data: +"".b, limit: MAX_OUTPUT_BYTES, overflow: false, open: true,
            consumer: stdout_consumer, consumer_error: nil
          },
          stderr_reader => {
            data: +"".b, limit: MAX_DIAGNOSTIC_BYTES, overflow: false, open: true,
            consumer: nil, consumer_error: nil
          }
        }
        deadline ||= monotonic_now + timeout_sec
        status = nil
        timed_out = false

        loop do
          status ||= wait_status(provider_pid)
          break if status
          if streams.values.any? { |stream| stream.fetch(:overflow) }
            break
          end
          if monotonic_now >= deadline
            timed_out = true
            break
          end

          drain_provider_streams(streams, [ deadline - monotonic_now, CUSTODY_POLL_SEC ].min)
        end

        descendants = supervisor_descendants
        leftover_processes = status && descendants.any? do |target|
          target.fetch(:pid) != provider_pid
        end
        cleanup_deadline = monotonic_now + CUSTODY_TERM_GRACE_SEC + CUSTODY_KILL_GRACE_SEC
        status, cleanup_failed = terminate_supervised_tree!(
          provider_pid, status, deadline: cleanup_deadline
        )
        drain_provider_streams_until(streams, cleanup_deadline)
        streams.each_key { |io| io.close unless io.closed? }
        status ||= wait_status(provider_pid)

        {
          "stdout" => Base64.strict_encode64(streams.fetch(stdout_reader).fetch(:data)),
          "stderr" => Base64.strict_encode64(streams.fetch(stderr_reader).fetch(:data)),
          "stdout_overflow" => streams.fetch(stdout_reader).fetch(:overflow),
          "stderr_overflow" => streams.fetch(stderr_reader).fetch(:overflow),
          "stdout_consumer_error" =>
            streams.fetch(stdout_reader).fetch(:consumer_error),
          "timed_out" => timed_out,
          "leftover_processes" => !!leftover_processes,
          "cleanup_failed" => cleanup_failed,
          "status" => serialize_status(status)
        }
      rescue StandardError
        emergency_terminate_provider!(provider_pid) if provider_pid
        raise
      ensure
        [ stdin_reader, stdin_writer, stdout_reader, stdout_writer,
          stderr_reader, stderr_writer ].each do |io|
          io&.close unless io&.closed?
        rescue IOError
          nil
        end
      end

      def drain_provider_streams_until(streams, deadline)
        while monotonic_now < deadline && streams.values.any? { |stream| stream.fetch(:open) }
          drain_provider_streams(streams, [ deadline - monotonic_now, CUSTODY_POLL_SEC ].min)
        end
      end

      def drain_provider_streams(streams, wait_seconds)
        open_ios = streams.filter_map { |io, stream| io if stream.fetch(:open) }
        return if open_ios.empty?

        ready = IO.select(open_ios, nil, nil, [ wait_seconds, 0 ].max)&.first || []
        ready.each do |io|
          stream = streams.fetch(io)
          loop do
            chunk = io.read_nonblock(8192, exception: false)
            break if chunk == :wait_readable
            if chunk.nil?
              finish_provider_stream_consumer(stream)
              stream[:open] = false
              io.close
              break
            end

            consume_provider_stream_chunk(stream, chunk)
            break if stream.fetch(:overflow)
          end
        rescue IOError, Errno::EBADF
          stream[:open] = false
        end
      end

      def consume_provider_stream_chunk(stream, chunk)
        return if stream.fetch(:consumer_error)

        consumer = stream.fetch(:consumer)
        if consumer
          consumer.write(chunk)
          return
        end

        remaining = stream.fetch(:limit) - stream.fetch(:data).bytesize
        stream.fetch(:data) << chunk.byteslice(0, remaining) if remaining.positive?
        stream[:overflow] = true if chunk.bytesize > remaining
      rescue StandardError => e
        stream[:consumer_error] = e.message
        stream[:overflow] = true
      end

      def finish_provider_stream_consumer(stream)
        return if stream.fetch(:consumer_error)

        stream.fetch(:consumer)&.finish
      rescue StandardError => e
        stream[:consumer_error] = e.message
        stream[:overflow] = true
      end

      def terminate_supervised_tree!(provider_pid, status, deadline:)
        term_deadline = [ monotonic_now + CUSTODY_TERM_GRACE_SEC, deadline ].min
        signal_supervisor_descendants("TERM")
        status = wait_for_supervised_exit(provider_pid, status, term_deadline)
        remaining = supervisor_descendants
        unless remaining.empty?
          signal_targets("KILL", remaining)
          status = wait_for_supervised_exit(provider_pid, status, deadline, signal: "KILL")
        end
        [ status, supervisor_descendants.any? ]
      end

      def wait_for_supervised_exit(provider_pid, status, deadline, signal: "TERM")
        loop do
          status ||= wait_status(provider_pid)
          reap_supervised_children if status
          remaining = supervisor_descendants
          return status if remaining.empty?
          return status if monotonic_now >= deadline

          signal_targets(signal, remaining)
          sleep CUSTODY_POLL_SEC
        end
      end

      def signal_supervisor_descendants(signal)
        signal_targets(signal, supervisor_descendants)
      end

      def signal_targets(signal, targets)
        Hive::ProcessKill.signal_captured_processes(
          signal, targets, require_identity: signal == "KILL"
        )
      end

      def supervisor_descendants
        confirmed_descendants(Process.pid)
      end

      def confirmed_descendants(root_pid)
        first = linux_descendant_snapshot(root_pid)
        confirmation = linux_descendant_snapshot(root_pid).to_h do |target|
          [ target.fetch(:pid), target ]
        end
        first.select do |target|
          current = confirmation[target.fetch(:pid)]
          current && current.fetch(:start_time) == target.fetch(:start_time)
        end
      end

      def linux_descendant_snapshot(root_pid)
        pending = linux_child_pids(root_pid, required: true).map { |pid| [ pid, 1 ] }
        seen = { root_pid => true }
        targets = []
        until pending.empty?
          pid, depth = pending.shift
          next if seen[pid]

          seen[pid] = true
          start_time = Hive::ProcessKill.process_start_time(pid)
          if start_time.to_s.empty?
            next unless Hive::ProcessKill.pid_alive?(pid)

            raise ProviderError, "provider process identity custody is unavailable"
          end
          targets << { pid: pid, start_time: start_time, depth: depth }
          linux_child_pids(pid, required: false).each do |child_pid|
            pending << [ child_pid, depth + 1 ]
          end
        end
        targets.sort_by { |target| [ -target.fetch(:depth), target.fetch(:pid) ] }
      end

      def linux_child_pids(pid, required:)
        task_root = "/proc/#{pid}/task"
        task_ids = Dir.children(task_root)
        task_ids.flat_map do |task_id|
          File.read(File.join(task_root, task_id, "children")).split.filter_map do |value|
            child_pid = Integer(value, 10)
            child_pid if Hive::ProcessKill.valid_target_pid?(child_pid)
          end
        rescue Errno::ENOENT
          []
        end.uniq
      rescue Errno::ENOENT
        raise ProviderError, "provider process-tree custody is unavailable" if required

        []
      rescue Errno::EACCES, Errno::EIO, ArgumentError
        raise ProviderError, "provider process-tree custody is unavailable"
      end

      def emergency_terminate_provider!(provider_pid)
        deadline = monotonic_now + CUSTODY_TERM_GRACE_SEC + CUSTODY_KILL_GRACE_SEC
        terminate_supervised_tree!(provider_pid, wait_status(provider_pid), deadline: deadline)
      rescue ProviderError
        signal_provider_group("TERM", provider_pid)
        sleep CUSTODY_POLL_SEC
        signal_provider_group("KILL", provider_pid)
      ensure
        reap_supervised_children
      end

      def signal_provider_group(signal, provider_pid)
        Process.kill(signal, -provider_pid)
        Process.kill(signal, provider_pid)
      rescue Errno::ESRCH
        nil
      end

      def wait_status(pid)
        waited = Process.waitpid2(pid, Process::WNOHANG)
        waited&.last
      rescue Errno::ECHILD
        nil
      end

      def reap_supervised_children
        loop do
          break unless Process.waitpid(-1, Process::WNOHANG)
        end
      rescue Errno::ECHILD
        nil
      end

      def serialize_status(status)
        return { "success" => false, "signaled" => false, "exitstatus" => nil, "termsig" => nil } unless status

        {
          "success" => status.success?,
          "signaled" => status.signaled?,
          "exitstatus" => status.exitstatus,
          "termsig" => status.termsig
        }
      end

      def write_supervisor_result(writer, payload)
        bytes = JSON.generate(payload)
        offset = 0
        while offset < bytes.bytesize
          offset += writer.write(bytes.byteslice(offset, bytes.bytesize - offset))
        end
      rescue SystemCallError, IOError
        nil
      end

      def read_supervisor_result(reader)
        data = +"".b
        loop do
          chunk = reader.readpartial(8192)
          if data.bytesize + chunk.bytesize > SUPERVISOR_RESULT_MAX_BYTES
            raise ProviderError, "project capture provider supervisor result exceeded its limit"
          end
          data << chunk
        end
      rescue EOFError
        data
      end

      def decode_supervisor_result(raw)
        payload = JSON.parse(raw)
        raise ProviderError, "project capture provider supervisor returned an invalid result" unless payload.is_a?(Hash)
        return payload if payload["internal_error"]

        payload["stdout"] = Base64.strict_decode64(payload.fetch("stdout"))
        payload["stderr"] = Base64.strict_decode64(payload.fetch("stderr"))
        payload
      rescue JSON::ParserError, ArgumentError, KeyError
        raise ProviderError, "project capture provider supervisor returned an invalid result"
      end

      def encode_supervisor_result(payload)
        return payload if payload["internal_error"]

        payload.merge(
          "stdout" => Base64.strict_encode64(payload.fetch("stdout")),
          "stderr" => Base64.strict_encode64(payload.fetch("stderr"))
        )
      end

      def enable_child_subreaper!
        unless RUBY_PLATFORM.include?("linux")
          raise ProviderError,
                "project capture provider custody requires Linux child-subreaper support"
        end

        prctl = Fiddle::Function.new(
          Fiddle::Handle::DEFAULT["prctl"],
          [ Fiddle::TYPE_INT, Fiddle::TYPE_LONG, Fiddle::TYPE_LONG,
            Fiddle::TYPE_LONG, Fiddle::TYPE_LONG ],
          Fiddle::TYPE_INT
        )
        result = prctl.call(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0)
        raise ProviderError, "provider child-subreaper custody is unavailable" unless result.zero?
      rescue Fiddle::DLError
        raise ProviderError, "provider child-subreaper custody is unavailable"
      end

      def disable_child_subreaper!
        prctl = Fiddle::Function.new(
          Fiddle::Handle::DEFAULT["prctl"],
          [ Fiddle::TYPE_INT, Fiddle::TYPE_LONG, Fiddle::TYPE_LONG,
            Fiddle::TYPE_LONG, Fiddle::TYPE_LONG ],
          Fiddle::TYPE_INT
        )
        result = prctl.call(PR_SET_CHILD_SUBREAPER, 0, 0, 0, 0)
        raise ProviderError, "provider child-subreaper custody could not be restored" unless result.zero?
      rescue Fiddle::DLError
        raise ProviderError, "provider child-subreaper custody could not be restored"
      end

      def child_subreaper_enabled?
        unless RUBY_PLATFORM.include?("linux")
          raise ProviderError,
                "project capture provider custody requires Linux child-subreaper support"
        end

        value = Fiddle::Pointer.malloc(Fiddle::SIZEOF_INT)
        value[0, Fiddle::SIZEOF_INT] = [ 0 ].pack("i")
        prctl = Fiddle::Function.new(
          Fiddle::Handle::DEFAULT["prctl"],
          [ Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG,
            Fiddle::TYPE_LONG, Fiddle::TYPE_LONG ],
          Fiddle::TYPE_INT
        )
        result = prctl.call(PR_GET_CHILD_SUBREAPER, value, 0, 0, 0)
        raise ProviderError, "provider child-subreaper custody is unavailable" unless result.zero?

        value[0, Fiddle::SIZEOF_INT].unpack1("i") == 1
      rescue Fiddle::DLError
        raise ProviderError, "provider child-subreaper custody is unavailable"
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def parse_result(stdout)
        document = JSON.parse(stdout)
        raise ProviderError, "project capture provider result must be a JSON object" unless document.is_a?(Hash)

        document
      rescue JSON::ParserError => e
        raise ProviderError,
              "project capture provider returned malformed JSON: #{bounded_diagnostic(e)}"
      end

      def validate_result_shape!(document)
        allowed = %w[schema schema_version status artifacts evidence cleanup diagnostic]
        unknown = document.keys - allowed
        missing = allowed - document.keys
        raise ProviderError, "project capture provider result has unknown keys: #{unknown.sort.join(', ')}" unless unknown.empty?
        raise ProviderError, "project capture provider result is missing keys: #{missing.sort.join(', ')}" unless missing.empty?
        unless document["schema"] == RESULT_SCHEMA &&
               document["schema_version"] == RESULT_SCHEMA_VERSION
          raise ProviderError, "project capture provider returned an unsupported result schema"
        end
        unless %w[captured failed].include?(document["status"])
          raise ProviderError, "project capture provider result has an invalid status"
        end
        unless document["artifacts"].is_a?(Array) && document["evidence"].is_a?(Hash) &&
               document["cleanup"].is_a?(Hash)
          raise ProviderError, "project capture provider result has invalid artifacts, evidence, or cleanup"
        end
        evidence_bytes = JSON.generate(document.fetch("evidence")).bytesize
        if evidence_bytes > MAX_EVIDENCE_BYTES
          raise ProviderError,
                "project capture provider evidence exceeded #{MAX_EVIDENCE_BYTES} bytes"
        end
        unless document["cleanup"] == CLEANUP
          raise ProviderError, "project capture provider did not report complete cleanup"
        end
        diagnostic = document["diagnostic"]
        unless diagnostic.nil? || (diagnostic.is_a?(String) && diagnostic.bytesize <= MAX_DIAGNOSTIC_BYTES)
          raise ProviderError, "project capture provider diagnostic is invalid or too large"
        end
        if document["status"] == "captured" && !diagnostic.nil?
          raise ProviderError, "captured provider result must have a null diagnostic"
        end
      end

      def validate_artifacts!(entries, staging_root)
        unless entries.length.between?(1, MAX_ARTIFACTS)
          raise ProviderError,
                "project capture provider must return between 1 and #{MAX_ARTIFACTS} artifacts"
        end
        seen = {}
        total = 0
        entries.map.with_index do |entry, index|
          unless entry.is_a?(Hash) && entry.keys.sort == %w[bytes file sha256]
            raise ProviderError, "project capture provider artifact #{index} has an invalid shape"
          end
          filename = entry["file"].to_s
          unless File.basename(filename) == filename && filename.match?(MEDIA_FILE)
            raise ProviderError, "project capture provider artifact #{index} has an unsafe filename"
          end
          raise ProviderError, "project capture provider returned duplicate artifact #{filename}" if seen[filename]
          seen[filename] = true
          path = File.join(staging_root, filename)
          stat = File.lstat(path)
          unless stat.file? && !stat.symlink? && stat.uid == Process.uid
            raise ProviderError, "project capture provider artifact #{filename} is not an owned regular file"
          end
          unless stat.size.positive? && stat.size <= MAX_ARTIFACT_BYTES
            raise ProviderError, "project capture provider artifact #{filename} has an invalid size"
          end
          unless File.realpath(path).start_with?("#{staging_root}#{File::SEPARATOR}")
            raise ProviderError, "project capture provider artifact #{filename} escapes staging"
          end
          unless entry["bytes"] == stat.size
            raise ProviderError, "project capture provider artifact #{filename} size does not match"
          end
          digest = ::Digest::SHA256.file(path).hexdigest
          unless entry["sha256"].to_s.match?(/\A[0-9a-f]{64}\z/) && entry["sha256"] == digest
            raise ProviderError, "project capture provider artifact #{filename} digest does not match"
          end
          validate_media_content!(path, filename, staging_root)
          total += stat.size
          raise ProviderError, "project capture provider artifacts exceed the total size limit" if
            total > MAX_TOTAL_ARTIFACT_BYTES

          {
            "file" => filename,
            "bytes" => stat.size,
            "sha256" => digest,
            "source_path" => path
          }.freeze
        rescue Errno::ENOENT, Errno::ENOTDIR
          raise ProviderError, "project capture provider artifact #{filename} is missing"
        end
      end

      def validate_media_content!(path, filename, staging_root)
        ffprobe = Hive::InvokedBinary.which("ffprobe", env: @environment)
        ffmpeg = Hive::InvokedBinary.which("ffmpeg", env: @environment)
        raise ProviderError, "ffprobe is required to validate project capture media" unless ffprobe
        raise ProviderError, "ffmpeg is required to decode project capture media" unless ffmpeg

        probe = media_tool_result(
          [
            ffprobe, "-v", "error", "-show_entries",
            "format=format_name,duration:stream=codec_name,codec_type",
            "-of", "json", path
          ],
          source_root: staging_root,
          timeout_sec: 10
        )
        document = if !probe["internal_error"] && !probe.fetch("timed_out") &&
                      !probe.fetch("cleanup_failed") && probe.fetch("status").fetch("success")
          JSON.parse(probe.fetch("stdout"))
        end
        extension = File.extname(filename).downcase
        stream = Array(document&.fetch("streams", nil)).find do |candidate|
          candidate.is_a?(Hash) && candidate["codec_type"] == "video"
        end
        codec = stream&.fetch("codec_name", nil)
        valid = case extension
        when ".png" then codec == "png"
        when ".jpg", ".jpeg" then codec == "mjpeg"
        when ".gif" then codec == "gif"
        when ".webp" then codec == "webp"
        when ".webm"
          playable_video?(document, stream, /(?:\A|,)matroska,webm(?:,|\z)|\Awebm\z/)
        when ".mp4"
          playable_video?(document, stream, /(?:\A|,)(?:mov|mp4)(?:,|\z)/)
        else
          false
        end
        decoded = media_tool_result(
          [
            ffmpeg, "-nostdin", "-v", "error", "-i", path, "-map", "0:v:0",
            "-frames:v", "1", "-f", "null", "-"
          ],
          source_root: staging_root,
          timeout_sec: 10
        )
        return if valid && decoded.fetch("status").fetch("success") &&
                  !decoded.fetch("timed_out") && !decoded.fetch("cleanup_failed")

        label = extension.delete_prefix(".").upcase
        raise ProviderError,
              "project capture provider artifact #{filename} is not valid decodable #{label} media"
      rescue JSON::ParserError, KeyError, TypeError
        label = File.extname(filename).delete_prefix(".").upcase
        raise ProviderError,
              "project capture provider artifact #{filename} is not valid decodable #{label} media"
      end

      def playable_video?(document, stream, format_pattern)
        return false unless stream

        format = document&.fetch("format", nil)
        return false unless format.is_a?(Hash)
        return false unless format.fetch("format_name", "").match?(format_pattern)

        Float(format["duration"], exception: false)&.positive? == true
      end

      def media_probe_environment
        SAFE_AMBIENT_KEYS.each_with_object({}) do |key, allowed|
          value = @environment[key]
          allowed[key] = value if value && !value.empty?
        end.tap { |allowed| allowed["PATH"] ||= "/usr/local/bin:/usr/bin:/bin" }
      end

      def media_tool_result(argv, source_root:, timeout_sec:)
        supervise_provider(
          argv,
          request: {},
          source_root: source_root,
          environment: media_probe_environment,
          timeout_sec: timeout_sec
        )
      end

      def validate_staging_inventory!(staging_root, artifacts)
        expected = artifacts.map { |artifact| artifact.fetch("file") }.sort
        actual = Dir.children(staging_root).sort
        return if actual == expected

        raise ProviderError,
              "project capture provider left undeclared or incomplete staging entries"
      end

      def reject_secret_shaped_output!(*values)
        hits = Hive::SecretPatterns.scan(values.join("\n"))
        return if hits.empty?

        names = hits.map { |hit| hit.fetch(:name) }.uniq.join(", ")
        raise ProviderError,
              "project capture provider output contains secret-shaped content: #{names}"
      end

      def ensure_private_directory!(path, label)
        stat = File.lstat(path)
        unless stat.directory? && !stat.symlink? && stat.uid == Process.uid
          raise ProviderError, "#{label} must be an owned regular directory"
        end
        FileUtils.chmod(0o700, path)
      end

      def bounded_diagnostic(value)
        text = value.respond_to?(:message) ? value.message : value.to_s
        Hive::SecretPatterns.redact(
          text.to_s.b.byteslice(0, MAX_DIAGNOSTIC_BYTES).to_s
              .force_encoding(Encoding::UTF_8).scrub
        )
      end
    end
  end
end
