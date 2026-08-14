require "json"
require "securerandom"
require "hive/artifacts/capture_mailbox"
require "hive/artifacts/outcome_evidence/recovery"
require "hive/artifacts/outcome_evidence/store"
require "hive/config"
require "hive/lock"
require "hive/markers"
require "hive/task_resolver"
require "hive/terminal_outcome"

module Hive
  module Commands
    # Exact-CAS operator recovery for an exhausted or explicitly blocked
    # outcome-evidence package. The command never mutates the blocked ledger;
    # it advances a separate epoch and leaves ordinary workflow.retry admission
    # to the existing status/action boundary.
    class Evidence
      SUBCOMMANDS = %w[browser recover terminal].freeze
      GATEWAY_TIMEOUT_SECONDS = 65
      CAPTURE_NAME = /\A[a-z][a-z0-9_-]{0,63}\z/

      def initialize(subcommand, target, project: nil, stage: nil, json: false,
                     generation: nil, recovery_digest: nil, task_resolver: nil,
                     command: [], environment: ENV)
        @subcommand = subcommand.to_s
        @target = target.to_s
        @project_filter = project
        @stage_filter = stage
        @json = json
        @generation = generation.to_s
        @recovery_digest = recovery_digest.to_s
        @task_resolver = task_resolver
        @command = Array(command).map(&:to_s)
        @environment = environment.to_h
      end

      def call
        validate_arguments!
        return capture_terminal if @subcommand == "terminal"
        return run_browser if @subcommand == "browser"

        task = resolve_task
        project = task.respond_to?(:project_name) ? task.project_name.to_s : @project_filter.to_s
        project = File.basename(task.project_root) if project.empty?
        payload = Hive::Lock.with_task_lock(
          task.folder, slug: task.slug, op: "outcome-evidence.recover"
        ) do
          recover(task, project)
        end
        if @json
          puts JSON.generate(payload)
        else
          puts "hive: outcome evidence recovery epoch advanced to #{payload.fetch('recovery_epoch')}"
          puts "  blocked generation preserved: #{payload.fetch('blocked_generation')}"
          puts "  next: refresh `hive status --operational --json` and invoke the task's guarded workflow.retry action"
        end
        payload
      end

      private

      def validate_arguments!
        unless SUBCOMMANDS.include?(@subcommand)
          raise Hive::UsageError,
                "unknown evidence subcommand #{@subcommand.inspect} " \
                "(expected: browser, recover, or terminal)"
        end
        if @subcommand == "browser"
          raise Hive::UsageError, "hive evidence browser requires COMMAND" if @target.empty?
          return
        end
        if @subcommand == "terminal"
          unless @target.match?(CAPTURE_NAME)
            raise Hive::UsageError, "hive evidence terminal requires a safe capture NAME"
          end
          raise Hive::UsageError, "hive evidence terminal requires COMMAND after --" if @command.empty?
          return
        end
        raise Hive::UsageError, "hive evidence recover requires TARGET" if @target.empty?
        unless @generation.match?(Hive::Artifacts::OutcomeEvidence::Proof::DIGEST)
          raise Hive::UsageError, "hive evidence recover requires --generation SHA256"
        end
        unless @recovery_digest.match?(Hive::Artifacts::OutcomeEvidence::Proof::DIGEST)
          raise Hive::UsageError, "hive evidence recover requires --recovery-digest SHA256"
        end
      end

      def capture_terminal
        response = gateway_request(
          "operation" => "terminal", "name" => @target, "argv" => @command
        )
        payload = response.fetch("payload")
        if @json
          puts JSON.generate(payload)
        else
          puts "hive: recorded terminal evidence #{payload.dig('representations', 0, 'path')}"
          puts "  review: #{payload.dig('representations', 1, 'path')}"
          puts "  exit: #{payload.fetch('exit_status')}"
        end
        payload
      end

      def run_browser
        payload = gateway_request(
          "operation" => "browser", "argv" => [ @target, *@command ]
        )
        $stdout.write(payload.fetch("stdout"))
        $stderr.write(payload.fetch("stderr"))
        unless payload.fetch("ok") && Integer(payload.fetch("status")).zero?
          raise Hive::UsageError, "browser command failed"
        end
        payload
      rescue JSON::ParserError, KeyError, TypeError, SystemCallError => e
        raise Hive::UsageError, "browser gateway is unavailable: #{e.message}"
      end

      def gateway_request(payload)
        root = @environment["HIVE_EVIDENCE_CAPTURE_MAILBOX"].to_s
        unless File.absolute_path?(root) && File.directory?(root)
          raise Hive::UsageError, "HIVE_EVIDENCE_CAPTURE_MAILBOX is unavailable"
        end
        stat = File.lstat(root)
        unless stat.directory? && !stat.symlink? && stat.uid == Process.uid
          raise Hive::UsageError, "HIVE_EVIDENCE_CAPTURE_MAILBOX is unavailable"
        end
        request_path = File.join(root, "requests.fifo")
        request_stat = File.lstat(request_path)
        unless request_stat.pipe? && !request_stat.symlink? && request_stat.uid == Process.uid
          raise Hive::UsageError, "capture gateway request boundary is unavailable"
        end
        reply_name = "reply-#{SecureRandom.hex(12)}.fifo"
        reply_path = File.join(root, reply_name)
        File.mkfifo(reply_path, 0o600)
        reader = File.open(reply_path, File::RDWR | File::NONBLOCK | File::NOFOLLOW)
        source = JSON.generate(payload.merge("reply" => reply_name)) << "\n"
        if source.bytesize > Hive::Artifacts::CaptureMailbox::MAX_REQUEST_BYTES
          raise Hive::UsageError, "capture gateway request is oversized"
        end
        File.open(request_path, File::WRONLY | File::NONBLOCK | File::NOFOLLOW) do |writer|
          unless writer.stat.pipe? &&
                 writer.stat.dev == request_stat.dev && writer.stat.ino == request_stat.ino
            raise Hive::UsageError, "capture gateway request boundary is unavailable"
          end
          write_gateway_request(writer, source)
        end
        response = read_gateway_response(reader)
        unless response.fetch("ok")
          detail = response["error"] || response["stderr"] || "capture gateway command failed"
          raise Hive::UsageError, detail
        end
        response
      rescue Errno::ENOENT, Errno::ELOOP, Errno::ENXIO, Errno::EPIPE, IOError => e
        raise Hive::UsageError, "capture gateway is unavailable: #{e.message}"
      ensure
        reader&.close unless reader&.closed?
        begin
          File.unlink(reply_path) if reply_path
        rescue Errno::ENOENT
          nil
        end
      end

      def write_gateway_request(writer, source)
        offset = 0
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        while offset < source.bytesize
          begin
            offset += writer.write_nonblock(source.byteslice(offset, source.bytesize - offset))
          rescue IO::WaitWritable
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            raise Hive::UsageError, "capture gateway request timed out" unless remaining.positive?

            IO.select(nil, [ writer ], nil, [ remaining, 0.1 ].min)
          end
        end
      end

      def read_gateway_response(reader)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + GATEWAY_TIMEOUT_SECONDS
        buffer = +"".b
        loop do
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          raise Hive::UsageError, "capture gateway timed out" unless remaining.positive?
          next unless IO.select([ reader ], nil, nil, [ remaining, 0.1 ].min)

          begin
            buffer << reader.read_nonblock(16 * 1024)
          rescue IO::WaitReadable
            next
          end
          if buffer.bytesize > Hive::Artifacts::CaptureMailbox::MAX_RESPONSE_BYTES
            raise Hive::UsageError, "capture gateway response is oversized"
          end
          next unless (newline = buffer.index("\n"))

          return JSON.parse(buffer.byteslice(0, newline + 1))
        end
      end

      def resolve_task
        return @task_resolver.call if @task_resolver

        Hive::TaskResolver.new(
          @target, project_filter: @project_filter, stage_filter: @stage_filter
        ).resolve
      end

      def recover(task, project)
        marker = Hive::Markers.current(task.state_file)
        unless marker.name == :error &&
               Hive::TerminalOutcome.blocked_error?(marker.attrs) &&
               marker.attrs["generation"].to_s == @generation &&
               marker.attrs["recovery_digest"].to_s == @recovery_digest
          raise Hive::Artifacts::OutcomeEvidence::StoreError,
                "task is not at the exact observed outcome-evidence blocker"
        end
        store = Hive::Artifacts::OutcomeEvidence::Store.new(task: task, project: project)
        package = store.package
        pointer = package.fetch("current")
        unless pointer.fetch("status") == "blocked"
          raise Hive::Artifacts::OutcomeEvidence::StoreError,
                "current outcome-evidence pointer is not blocked"
        end
        requirement = package.fetch("requirement")
        task_generation = requirement.fetch("task_generation")
        record = Hive::Artifacts::OutcomeEvidence::Recovery.new(
          task: task, project: project
        ).advance!(
          pointer: pointer, task_generation: task_generation,
          expected_generation: @generation, expected_digest: @recovery_digest
        )
        Hive::Markers.set(
          task.state_file, :error,
          reason: "outcome_evidence_recovery_ready",
          generation: @generation,
          recovery_digest: @recovery_digest,
          recovery_epoch: record.fetch("epoch")
        )
        {
          "status" => "recovery_ready",
          "task" => task.slug.to_s,
          "blocked_generation" => record.fetch("blocked_generation"),
          "recovery_epoch" => record.fetch("epoch")
        }
      end
    end
  end
end
