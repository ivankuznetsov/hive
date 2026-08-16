require "hive/attempts/capability"
require "hive/attempts/evidence_channel"
require "hive/attempts/store"
require "hive/stringify_keys"

module Hive
  module Attempts
    # Application-scoped, process-local identity installed by the durable worker.
    # Compatibility projections can only observe it after the admitted worker
    # has matched its immutable lease, task/stage binding, and live process
    # fingerprint. Transport environment is scrubbed immediately afterwards.
    class Context
      ENV_PREFIX = "HIVE_ATTEMPT_"
      EMPTY_ROUTING_VALUES = [].freeze

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
            # Compatibility consumers have always treated task_generation as
            # the opaque durable owner token. Keep that wire meaning stable;
            # the numeric condition epoch is additive and explicitly named.
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
          raise StoreError, "durable attempt worker gate was not released" unless gate == "1"

          attempt_id = values["HIVE_ATTEMPT_ID"].to_s
          raise StoreError, "durable attempt context is incomplete" if attempt_id.empty?

          # The record store is selected by trusted Hive process configuration,
          # not by a dedicated attempt-context override. This prevents supported
          # launch/inheritance paths from redirecting context installation; it
          # is not privilege separation from hostile same-UID process state.
          record = Store.new.fetch(attempt_id)
          validate_record!(record, attempt_id: attempt_id, argv: argv, claim_capability: claim_capability)
          evidence_writer = if record["routing"]["mode"] == "explicit"
            EvidenceChannel::Writer.for_fd(
              values["HIVE_ATTEMPT_EVIDENCE_FD"],
              route: record["routing"].fetch("route")
            )
          end
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
            evidence_writer: evidence_writer
          )
        rescue Hive::Error, SystemCallError, IOError => e
          raise StoreError, "durable attempt context rejected: #{e.message}"
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
          raise StoreError, "attempt #{attempt_id} is unavailable" unless record
          raise StoreError, "attempt identity mismatch" unless record.attempt_id == attempt_id
          raise StoreError, "attempt is not running" unless record.state == "running"
          unless Capability.matches?(record["claim_capability_digest"], claim_capability)
            raise StoreError, "attempt context capability is invalid"
          end
          unless record["worker_argv"] == argv
            raise StoreError, "attempt worker argv does not match admission"
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
          raise StoreError, "attempt worker process identity mismatch" unless expected == actual
        end

        def validate_task_binding!(record, argv)
          if record.respond_to?(:module_hook?) && record.module_hook?
            validate_module_hook_binding!(record, argv)
            return
          end

          require "hive/task_resolver"
          require "hive/workflows"
          verb = argv[1].to_s
          target = argv[2].to_s
          raise StoreError, "attempt worker command has no task target" if verb.empty? || target.empty?

          task = Hive::TaskResolver.new(target, project_filter: record["project"]).resolve
          intended_stage = if %w[run approve plan-review-run].include?(verb)
            "#{task.stage_index}-#{task.stage_name}"
          else
            Hive::Workflows.for_verb(verb).fetch(:target)
          end
          same_task_id = record["task_id"].nil? || task.id.to_s == record["task_id"].to_s
          unless same_task_id && task.slug == record["task_slug"] && intended_stage == record["intended_stage"]
            raise StoreError, "attempt task or intended stage does not match admission"
          end
        rescue KeyError, Hive::Error => e
          raise StoreError, "attempt task binding could not be resolved: #{e.message}"
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
          raise StoreError, "attempt module hook binding does not match admission" unless valid
        rescue KeyError
          raise StoreError, "attempt module hook binding is incomplete"
        end

        def read_inherited(value, limit:)
          io = IO.for_fd(Integer(value), "r", autoclose: true)
          payload = io.read(limit)
          extra = io.read(1)
          raise StoreError, "attempt context descriptor payload is invalid" unless extra.to_s.empty?

          payload
        rescue ArgumentError, TypeError, Errno::EBADF
          raise StoreError, "attempt context descriptor is unavailable"
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
                     progress_token: nil, predecessor_attempt_id: nil)
        @attempt_id = attempt_id.to_s
        @task_generation, bridged_ownership = numeric_generation_or_legacy(task_generation)
        @legacy_opaque_generation = !bridged_ownership.nil? && ownership_generation.nil?
        @ownership_generation = ownership_generation&.to_s || bridged_ownership
        @project = project&.to_s
        @task_slug = task_slug&.to_s
        @intended_stage = intended_stage&.to_s
        @progress_token = progress_token&.to_s
        @predecessor_attempt_id = predecessor_attempt_id&.to_s
        @routing = deep_freeze(Hive::StringifyKeys.call(routing))
        @evidence_writer = evidence_writer
        raise ArgumentError, "attempt context requires an attempt ID" if @attempt_id.empty?
        raise ArgumentError, "attempt context task generation must be non-negative" if @task_generation.negative?
      rescue TypeError
        raise ArgumentError, "attempt context requires a numeric task generation"
      end

      def explicit_routing? = routing["mode"] == "explicit"
      def routing_decision = explicit_routing? ? routing.fetch("decision") : nil
      def admitted_route = explicit_routing? ? routing.fetch("route") : nil
      def circuit_generations = explicit_routing? ? routing.fetch("circuit_generations") : EMPTY_ROUTING_VALUES
      def probe_bindings = explicit_routing? ? routing.fetch("probe_bindings") : EMPTY_ROUTING_VALUES
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

      def close
        @evidence_writer&.close
        true
      end

      # Revalidate the admitted generation at the command's locked mutation
      # boundary. A dependency or task artifact may change after dispatch but
      # before the detached worker starts; that stale worker must not perform
      # side effects and then cause the refreshed generation to run them again.
      def validate_generation!(task)
        return true if @generation_validated

        require "hive/attempts/generation"
        current = Generation.resolve(
          task: task, project: project, intended_stage: intended_stage
        )
        ownership_matches = current.ownership_generation == ownership_generation
        successor_progress_matches = !predecessor_attempt_id.to_s.empty? &&
                                     !progress_token.to_s.empty? &&
                                     current.respond_to?(:progress_token) &&
                                     current.progress_token == progress_token
        epoch_matches = @legacy_opaque_generation || current.task_input_epoch == task_generation
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

      def numeric_generation_or_legacy(value)
        return [ Integer(value), nil ] if value.is_a?(Integer) || value.to_s.match?(/\A\d+\z/)

        token = value.to_s
        raise ArgumentError, "attempt context requires a task generation" if token.empty?

        [ 0, token ]
      end

      private_class_method :new
    end
  end
end
