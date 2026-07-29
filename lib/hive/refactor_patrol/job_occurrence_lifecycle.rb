require "hive/modules/migration/occurrence_journal"

module Hive
  module RefactorPatrol
    # Facade over ArchitectureOccurrenceStore for the JobStore-facing
    # occurrence, effect, and recovery protocol. The occurrence store remains
    # the journal adapter; this collaborator adds only aggregate transition
    # validation that depends on JobStore's record contract.
    class JobOccurrenceLifecycle
      FORWARDED_METHODS = {
        reserve_manifest_occurrence!: :reserve_manifest!,
        reserve_occurrence!: :reserve!,
        occurrence_for_job: :fetch_for_job,
        occurrence_capture: :capture_for_job,
        each_recovery_active_occurrence: :each_recovery_active,
        recovery_active?: :recovery_active?,
        rebuild_recovery_index!: :rebuild_recovery_index!,
        recovery_backoff: :recovery_backoff,
        record_recovery_failure!: :record_recovery_failure!,
        clear_recovery_failure!: :clear_recovery_failure!,
        prepare_effect!: :prepare_effect!,
        effect_state: :effect_state,
        effect_intent: :effect_intent,
        with_effect_sender_lock: :with_effect_sender_lock,
        mark_dispatch_uncertain!: :mark_dispatch_uncertain!,
        reset_effect_prepared!: :reset_effect_prepared!,
        settle_effect!: :settle_effect!,
        deny_effect!: :deny_effect!,
        effect_receipt: :effect_receipt,
        terminal_effect_receipt_ids: :terminal_effect_receipt_ids,
        finalize_occurrence!: :finalize!,
        drain_occurrence_outbox!: :drain_outbox!
      }.freeze
      MUTATING_METHODS = %i[
        reserve_manifest_occurrence!
        reserve_occurrence!
        each_recovery_active_occurrence
        recovery_active?
        rebuild_recovery_index!
        recovery_backoff
        record_recovery_failure!
        clear_recovery_failure!
        prepare_effect!
        with_effect_sender_lock
        mark_dispatch_uncertain!
        reset_effect_prepared!
        settle_effect!
        deny_effect!
        finalize_occurrence!
        drain_occurrence_outbox!
      ].freeze

      FORWARDED_METHODS.each do |public_name, occurrence_name|
        define_method(public_name) do |*args, **options, &block|
          @before_mutation.call if MUTATING_METHODS.include?(public_name)
          occurrence_store.public_send(occurrence_name, *args, **options, &block)
        end
      end

      def initialize(architecture_occurrences:, inconsistent_record:,
                     record_validator:, aggregate_reader:, job_path:,
                     before_mutation: -> { })
        @inconsistent_record = inconsistent_record
        @record_validator = record_validator
        @aggregate_reader = aggregate_reader
        @job_path = job_path
        @before_mutation = before_mutation
        @occurrences = architecture_occurrences
      end

      def recorded_effect_transitions(job)
        collect_recorded_effect_transitions(aggregate_for(job))
      end

      def unsettled_recorded_transitions(job)
        aggregate = aggregate_for(job)
        occurrence_id = aggregate.fetch("occurrence_id")
        collect_recorded_effect_transitions(aggregate).filter_map do |transition|
          intent = effect_intent(occurrence_id, transition.fetch("intent_id"))
          validate_transition!(transition, intent, aggregate)
          state = effect_state(intent)
          next if state && Hive::Modules::Migration::OccurrenceJournal::
                            TERMINAL_STATES.include?(state.fetch("state"))

          [ intent, transition ]
        end
      end

      def assert_recorded_transitions_terminal!(job)
        return true if unsettled_recorded_transitions(job).empty?

        raise @inconsistent_record, "prior recorded transitions are not terminal"
      end

      private

      def aggregate_for(job) = @aggregate_reader.call(job)

      def occurrence_store
        @occurrences.respond_to?(:call) ? @occurrences.call : @occurrences
      end

      def validate_transition!(transition, intent, aggregate)
        if transition.key?("semantic_digest")
          @record_validator.validate_transition_semantic!(
            transition,
            semantic: intent,
            path: @job_path.call(aggregate.fetch("job_id"))
          )
        elsif transition.fetch("intent_id") != aggregate.fetch("intake_transition_id")
          raise @inconsistent_record,
                "recorded transition has no exact semantic digest"
        end
      end

      def collect_recorded_effect_transitions(aggregate)
        intake = {
          "intent_id" => aggregate.fetch("intake_transition_id"),
          "outcome" => "applied",
          "error_code" => nil
        }
        entries = [ intake ]
        aggregate.fetch("attempts").each { |attempt| entries.concat(Array(attempt["transitions"])) }
        aggregate.fetch("actions").each { |action| entries.concat(action.fetch("transitions")) }
        entries.each_with_object({}) do |entry, unique|
          intent_id = entry.fetch("intent_id")
          existing = unique[intent_id]
          if existing && existing != entry
            raise @inconsistent_record,
                  "refactor patrol transition identity conflicts"
          end
          unique[intent_id] = entry
        end.values
      end
    end
  end
end
