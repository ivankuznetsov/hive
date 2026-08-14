require "json"
require "pathname"
require "socket"
require "hive/artifacts/terminal_recorder"
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
      MAX_BROWSER_RESPONSE_BYTES = 512 * 1024
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
        task_root = required_owned_directory("HIVE_EVIDENCE_TASK_ROOT")
        source_root = required_owned_directory("HIVE_EVIDENCE_SOURCE_ROOT")
        writable_root = required_owned_directory("HIVE_EVIDENCE_WRITE_ROOT")
        task_real = File.realpath(task_root)
        writable_real = File.realpath(writable_root)
        unless writable_real.start_with?("#{task_real}#{File::SEPARATOR}")
          raise Hive::UsageError,
                "HIVE_EVIDENCE_WRITE_ROOT must be inside HIVE_EVIDENCE_TASK_ROOT"
        end
        cast = File.join(writable_real, "#{@target}.cast")
        review = File.join(writable_real, "#{@target}.txt")
        if [ cast, review ].any? { |path| File.exist?(path) || File.symlink?(path) }
          raise Hive::UsageError, "terminal capture NAME already exists in the evidence-write root"
        end
        ambient = %w[PATH LANG LC_ALL LC_CTYPE TERM COLORTERM TZ].to_h do |name|
          [ name, @environment[name] ]
        end.compact
        result = Hive::Artifacts::TerminalRecorder.new(
          argv: @command, cwd: source_root,
          cast_path: cast, review_path: review,
          environment: ambient
        ).record!
        result.fetch("representations").each do |representation|
          representation["path"] = Pathname.new(representation.fetch("path"))
            .relative_path_from(Pathname.new(task_real)).to_s
        end
        payload = { "status" => "captured" }.merge(result)
        if @json
          puts JSON.generate(payload)
        else
          puts "hive: recorded terminal evidence #{payload.dig('representations', 0, 'path')}"
          puts "  review: #{payload.dig('representations', 1, 'path')}"
          puts "  exit: #{payload.fetch('exit_status')}"
        end
        payload
      rescue Hive::Artifacts::TerminalRecorder::CaptureError => e
        raise Hive::UsageError, e.message
      end

      def run_browser
        socket_path = @environment["HIVE_EVIDENCE_BROWSER_SOCKET"].to_s
        stat = File.lstat(socket_path) if File.absolute_path?(socket_path)
        unless stat&.socket? && !stat.symlink? && stat.uid == Process.uid
          raise Hive::UsageError, "HIVE_EVIDENCE_BROWSER_SOCKET is unavailable"
        end
        socket = UNIXSocket.new(socket_path)
        socket.write(JSON.generate("argv" => [ @target, *@command ]) << "\n")
        response = socket.gets(MAX_BROWSER_RESPONSE_BYTES + 1)
        unless response && response.bytesize <= MAX_BROWSER_RESPONSE_BYTES && response.end_with?("\n")
          raise Hive::UsageError, "browser gateway returned an invalid response"
        end
        payload = JSON.parse(response)
        $stdout.write(payload.fetch("stdout"))
        $stderr.write(payload.fetch("stderr"))
        unless payload.fetch("ok") && Integer(payload.fetch("status")).zero?
          raise Hive::UsageError, "browser command failed"
        end
        payload
      rescue JSON::ParserError, KeyError, TypeError, SystemCallError => e
        raise Hive::UsageError, "browser gateway is unavailable: #{e.message}"
      ensure
        socket&.close
      end

      def required_owned_directory(name)
        value = @environment[name].to_s
        unless File.absolute_path?(value) && File.directory?(value)
          raise Hive::UsageError, "#{name} must name an existing absolute directory"
        end
        stat = File.lstat(value)
        unless stat.directory? && !stat.symlink? && stat.uid == Process.uid
          raise Hive::UsageError, "#{name} must be an owner-controlled directory"
        end
        value
      rescue Errno::ENOENT, Errno::ELOOP
        raise Hive::UsageError, "#{name} is unavailable"
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
