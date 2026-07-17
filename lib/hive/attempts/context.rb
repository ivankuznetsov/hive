require "hive/attempts/capability"
require "hive/attempts/store"

module Hive
  module Attempts
    # Authenticated, process-local identity installed by the durable worker.
    # Compatibility projections can only observe it after the admitted worker
    # has matched its immutable lease, task/stage binding, and live process
    # fingerprint. Transport environment is scrubbed immediately afterwards.
    class Context
      ENV_PREFIX = "HIVE_ATTEMPT_"

      attr_reader :attempt_id, :task_generation, :task_slug, :intended_stage

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
            "task_generation" => context.task_generation
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

          # The record store is the process-configured Hive authority. A path
          # supplied by the worker environment would let an untrusted task
          # manufacture a self-consistent record and capability in its
          # worktree, then skip public admission for another task.
          record = Store.new.fetch(attempt_id)
          validate_record!(record, attempt_id: attempt_id, argv: argv, claim_capability: claim_capability)
          @installed = new(
            attempt_id: record.attempt_id,
            task_generation: record.task_generation,
            task_slug: record["task_slug"],
            intended_stage: record["intended_stage"]
          )
        rescue Hive::Error, SystemCallError, IOError => e
          raise StoreError, "durable attempt context rejected: #{e.message}"
        ensure
          scrub_environment!
        end

        # Test isolation for the otherwise process-lifetime installation.
        def reset!
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
          require "hive/task_resolver"
          require "hive/workflows"
          verb = argv[1].to_s
          target = argv[2].to_s
          raise StoreError, "attempt worker command has no task target" if verb.empty? || target.empty?

          task = Hive::TaskResolver.new(target, project_filter: record["project"]).resolve
          intended_stage = if verb == "run"
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

      def initialize(attempt_id:, task_generation:, task_slug: nil, intended_stage: nil)
        @attempt_id = attempt_id.to_s
        @task_generation = task_generation.to_s
        @task_slug = task_slug&.to_s
        @intended_stage = intended_stage&.to_s
        raise ArgumentError, "attempt context requires an attempt ID" if @attempt_id.empty?
        raise ArgumentError, "attempt context requires a task generation" if @task_generation.empty?
      end

      private_class_method :new
    end
  end
end
