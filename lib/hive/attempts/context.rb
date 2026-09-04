require "hive/attempts/capability"
require "hive/attempts/command_progress"
require "hive/attempts/diagnostic_channel"
require "hive/attempts/evidence_channel"
require "hive/attempts/repository"
require "hive/stringify_keys"

module Hive
  module Attempts
    # Application-scoped, process-local identity installed by the durable worker.
    # Compatibility projections can only observe it after the admitted worker
    # has matched its immutable lease, task/stage binding, and live process
    # fingerprint. Transport environment is scrubbed immediately afterwards.
    class Context
      ENV_PREFIX = "HIVE_ATTEMPT_"
      attr_reader :attempt_id, :task_generation, :ownership_generation,
                  :project, :task_slug, :intended_stage, :routing,
                  :progress_token, :predecessor_attempt_id

      class << self
        def current
          @installed
        end

        def active?
          !current.nil?
        end

        def projection
          context = current
          return {} unless context

          {
            "attempt_id" => context.attempt_id,
            # Ownership and the numeric task-input epoch are distinct.
            "task_generation" => context.ownership_generation,
            "ownership_generation" => context.ownership_generation,
            "task_input_epoch" => context.task_generation
          }
        end

        # Called once by bin/hive before CLI dispatch. The gate is released
        # only after Supervisor has durably recorded this exact worker.
        def install_from_env!(argv:)
          return nil unless ENV["HIVE_ATTEMPT_INTERNAL"] == "1"

          values = ENV.to_h
          scrub_environment!
          claim_capability = read_inherited(values["HIVE_ATTEMPT_CONTEXT_FD"], limit: 65)
          gate = read_inherited(values["HIVE_ATTEMPT_GATE_FD"], limit: 1)
          raise RepositoryError, "durable attempt worker gate was not released" unless gate == "1"

          attempt_id = values["HIVE_ATTEMPT_ID"].to_s
          raise RepositoryError, "durable attempt context is incomplete" if attempt_id.empty?

          # The record store is selected by trusted Hive process configuration,
          # not by a dedicated attempt-context override. This prevents supported
          # launch/inheritance paths from redirecting context installation; it
          # is not privilege separation from hostile same-UID process state.
          record = Repository.open_default.fetch(attempt_id)
          validate_record!(record, attempt_id: attempt_id, argv: argv, claim_capability: claim_capability)
          evidence_writer = if record["routing"]["mode"] == "explicit"
            EvidenceChannel::Writer.for_fd(
              values["HIVE_ATTEMPT_EVIDENCE_FD"],
              route: record["routing"].fetch("route")
            )
          end
          diagnostic_writer = DiagnosticChannel::Writer.for_fd(
            values["HIVE_ATTEMPT_DIAGNOSTIC_FD"]
          )
          @installed = new(
            attempt_id: record.attempt_id,
            task_generation: record.task_input_epoch,
            ownership_generation: record.ownership_generation,
            project: record["project"],
            task_slug: record["task_slug"],
            intended_stage: record["intended_stage"],
            progress_token: record["progress_token"],
            predecessor_attempt_id: record["predecessor_attempt_id"],
            routing: record["routing"],
            evidence_writer: evidence_writer,
            diagnostic_writer: diagnostic_writer
          )
        rescue Hive::Error, SystemCallError, IOError => e
          raise RepositoryError, "durable attempt context rejected: #{e.message}"
        ensure
          scrub_environment!
        end

        # Test isolation for the otherwise process-lifetime installation.
        def reset!
          @installed&.close
          @installed = nil
        end

        private

        def validate_record!(record, attempt_id:, argv:, claim_capability:)
          raise RepositoryError, "attempt #{attempt_id} is unavailable" unless record
          raise RepositoryError, "attempt identity mismatch" unless record.attempt_id == attempt_id
          raise RepositoryError, "attempt is not running" unless record.state == "running"
          unless Capability.matches?(record["claim_capability_digest"], claim_capability)
            raise RepositoryError, "attempt context capability is invalid"
          end
          unless record["worker_argv"] == argv
            raise RepositoryError, "attempt worker argv does not match admission"
          end
          validate_process_identity!(record.worker)
          validate_task_binding!(record, argv)
        end

        def validate_process_identity!(expected)
          require "hive/lock"
          actual = {
            "pid" => Process.pid,
            "start_fingerprint" => Hive::Lock.process_start_time(Process.pid),
            "session_id" => Process.getsid(Process.pid),
            "process_group_id" => Process.getpgid(Process.pid)
          }
          raise RepositoryError, "attempt worker process identity mismatch" unless expected == actual
        end

        def validate_task_binding!(record, argv)
          if record.respond_to?(:module_hook?) && record.module_hook?
            validate_module_hook_binding!(record, argv)
            return
          end

          require "hive/task_resolver"
          require "hive/workflows"
          verb = argv[1].to_s
          evidence_rework = verb == "evidence" && argv[2].to_s == "rework"
          target = argv[evidence_rework ? 3 : 2].to_s
          raise RepositoryError, "attempt worker command has no task target" if verb.empty? || target.empty?

          task = Hive::TaskResolver.new(target, project_filter: record["project"]).resolve
          intended_stage = if evidence_rework || %w[run approve plan-review-run].include?(verb)
            "#{task.stage_index}-#{task.stage_name}"
          else
            Hive::Workflows.for_verb(verb).fetch(:target)
          end
          same_task_id = record["task_id"].nil? || task.id.to_s == record["task_id"].to_s
          unless same_task_id && task.slug == record["task_slug"] && intended_stage == record["intended_stage"]
            raise RepositoryError, "attempt task or intended stage does not match admission"
          end
        rescue KeyError, Hive::Error => e
          raise RepositoryError, "attempt task binding could not be resolved: #{e.message}"
        end

        def validate_module_hook_binding!(record, argv)
          subject = record.subject
          options = argv.each_cons(2).to_h
          valid = argv[1] == "__module-hook" &&
                  argv[2] == subject.fetch("module") &&
                  argv[3] == subject.fetch("hook") &&
                  options["--project"] == record["project"] &&
                  options["--event-id"] == subject.fetch("event_id") &&
                  record["task_id"].nil? &&
                  record["intended_stage"] == "module-hook"
          raise RepositoryError, "attempt module hook binding does not match admission" unless valid
        rescue KeyError
          raise RepositoryError, "attempt module hook binding is incomplete"
        end

        def read_inherited(value, limit:)
          io = IO.for_fd(Integer(value), "r", autoclose: true)
          payload = io.read(limit)
          extra = io.read(1)
          raise RepositoryError, "attempt context descriptor payload is invalid" unless extra.to_s.empty?

          payload
        rescue ArgumentError, TypeError, Errno::EBADF
          raise RepositoryError, "attempt context descriptor is unavailable"
        ensure
          io&.close unless io&.closed?
        end

        def scrub_environment!
          ENV.keys.grep(/\A#{ENV_PREFIX}/).each { |key| ENV.delete(key) }
        end
      end

      def initialize(attempt_id:, task_generation:, ownership_generation: nil,
                     project: nil, task_slug: nil, intended_stage: nil,
                     routing: { "mode" => "legacy" }, evidence_writer: nil,
                     diagnostic_writer: nil,
                     progress_token: nil, predecessor_attempt_id: nil)
        @attempt_id = attempt_id.to_s
        @task_generation = Integer(task_generation)
        @ownership_generation = ownership_generation&.to_s
        @project = project&.to_s
        @task_slug = task_slug&.to_s
        @intended_stage = intended_stage&.to_s
        @progress_token = progress_token&.to_s
        @predecessor_attempt_id = predecessor_attempt_id&.to_s
        @routing = deep_freeze(Hive::StringifyKeys.call(routing))
        @evidence_writer = evidence_writer
        @diagnostic_writer = diagnostic_writer
        raise ArgumentError, "attempt context requires an attempt ID" if @attempt_id.empty?
        raise ArgumentError, "attempt context task generation must be non-negative" if @task_generation.negative?
      rescue TypeError
        raise ArgumentError, "attempt context requires a numeric task generation"
      end

      def explicit_routing? = routing["mode"] == "explicit"
      def admitted_route = explicit_routing? ? routing.fetch("route") : nil
      def provider_account_id = admitted_route&.fetch("provider_account_id", nil)
      def adapter = admitted_route&.fetch("adapter", nil)
      def launch_binding_id = admitted_route&.fetch("launch_binding_id", nil)
      def model = admitted_route&.fetch("model", nil)
      def effort = admitted_route&.fetch("effort", nil)
      def billing_route = admitted_route&.fetch("billing_route", "unknown") || "unknown"
      def billing_evidence_source
        admitted_route&.fetch("billing_evidence_source", "unavailable") || "unavailable"
      end

      def publish_provider_signal(signal)
        return false unless explicit_routing? && @evidence_writer

        @evidence_writer.write(signal)
      end

      def publish_attempt_diagnostic(document)
        return false unless @diagnostic_writer

        @diagnostic_writer.write(document)
      end

      def close
        @evidence_writer&.close
        @diagnostic_writer&.close
        true
      end

      # Revalidate the admitted generation at the command's locked mutation
      # boundary. A dependency or task artifact may change after dispatch but
      # before the detached worker starts; that stale worker must not perform
      # side effects and then cause the refreshed generation to run them again.
      def validate_generation!(task)
        return true if @generation_validated

        require "hive/attempts/generation"
        generation_options = {
          task: task, project: project, intended_stage: intended_stage
        }
        if CommandProgress.task_progress?(task)
          fallback = Generation.artifact_token(task)
          generation_options[:progress_token] = CommandProgress.task_token_for(
            task: task, fallback: fallback
          )
        end
        current = Generation.resolve(**generation_options)
        ownership_matches = current.ownership_generation == ownership_generation
        successor_progress_matches = !predecessor_attempt_id.to_s.empty? &&
                                     !progress_token.to_s.empty? &&
                                     current.respond_to?(:progress_token) &&
                                     current.progress_token == progress_token
        epoch_matches = current.task_input_epoch == task_generation
        unless (ownership_matches || successor_progress_matches) && epoch_matches
          raise Hive::ConcurrentRunError,
                "durable attempt #{attempt_id} generation is stale; redispatch the current task state"
        end

        @generation_validated = true
      end

      private

      def deep_freeze(value)
        case value
        when Hash
          value.each { |key, child| key.freeze; deep_freeze(child) }
        when Array
          value.each { |child| deep_freeze(child) }
        when String
          value.freeze
        end
        value.freeze
      end

      private_class_method :new
    end
  end
end
