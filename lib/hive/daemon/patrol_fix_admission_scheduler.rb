require "hive/patrol_fix/admission_store"
require "hive/patrol_fix/semantic_admission"
require "hive/patrol_fix/source_snapshot"
require "digest"
require "securerandom"
require "shellwords"

module Hive
  module Daemon
    # Dedicated controller for post-discovery handoffs. It has no dependency on
    # PatrolScheduler, PatrolArbiter, or LaunchBudget; callers inject the normal
    # workflow-capacity predicate and provider-backed semantic admission port.
    class PatrolFixAdmissionScheduler
      Event = Struct.new(
        :source, :occurrence_id, :status, :task_slug, :retry_at, :reason,
        :command, :dispatch_token, keyword_init: true
      )
      RETRY_BACKOFF_SEC = [ 60, 300, 900 ].freeze
      DECISION_LEASE_SEC = 7_200

      def initialize(sources: [], admission_store: nil,
                     admission_store_factory: nil,
                     semantic_admission_factory: nil,
                     task_materializer_factory: nil,
                     semantic_command_factory: nil,
                     capacity_available: ->(**) { true },
                     retry_policy: nil, clock: -> { Time.now.utc }, limit: 16)
        @sources = sources
        @admission_store = admission_store
        @admission_store_factory = admission_store_factory
        @semantic_admission_factory = semantic_admission_factory
        @task_materializer_factory = task_materializer_factory
        @semantic_command_factory = semantic_command_factory || method(:semantic_command)
        @capacity_available = capacity_available
        @retry_policy = retry_policy || method(:default_retry_at)
        @clock = clock
        @limit = Integer(limit)
        raise ArgumentError, "Patrol Fix admission limit must be between 1 and 64" unless
          (1..64).cover?(@limit)
      end

      def tick(now: @clock.call)
        events = []
        remaining = @limit
        source_ports.each do |source|
          break if remaining.zero?
          next unless source.enabled?

          source.pending(limit: remaining, now: now).each do |entry|
            break if remaining.zero?
            remaining -= 1
            result = process(source, entry, now: now)
            events << result
            return events.freeze if result.status == :decision_dispatch
          end
        end
        events.freeze
      end

      # Existing ChildSupervisor completion hook. The semantic child is the
      # only actor allowed to settle a decision; completion only converts an
      # exact still-live failed reservation into bounded retry state.
      def complete(dispatch_token:, exit_code:, envelope:, now: @clock.call)
        token = symbolize_keys(dispatch_token)
        return unless token[:kind] == :patrol_fix_semantic_admission

        source = source_for_token(token)
        return event_from_token(token, :stale, reason: "source_unavailable") unless source

        store = store_for(source, {})
        record = store.fetch(token.fetch(:occurrence_id))
        if record && %w[decided blocked materializing bound acknowledged].include?(record.fetch("status"))
          return event_from_token(token, :decision_completed)
        end
        reservation = record && record["decision_reservation"]
        return event_from_token(token, :stale, reason: "reservation_changed") unless
          reservation && reservation.fetch("reservation_id") == token.fetch(:reservation_id)
        if exit_code.to_i.zero? && record.fetch("status") != "deciding"
          return event_from_token(token, :decision_completed)
        end

        error = CompletionFailure.new(envelope)
        retry_at = @retry_policy.call(record, error, now)
        store.record_provider_retry!(
          token.fetch(:occurrence_id), reservation_id: token.fetch(:reservation_id),
          reason: "provider_failure", error_class: error.error_class,
          retry_at: retry_at, now: now
        )
        source.defer!(
          occurrence_id: token.fetch(:occurrence_id), retry_at: retry_at, now: now
        )
        event_from_token(token, :retry_wait, retry_at: retry_at, reason: "provider_failure")
      rescue Hive::PatrolFix::AdmissionStore::StaleDecision
        event_from_token(token, :stale, reason: "reservation_expired")
      rescue StandardError => error
        event_from_token(
          token || {}, :failed,
          reason: "completion_failure: #{error.class}: #{bounded_error(error)}"
        )
      end


      def cancel(dispatch_token:, now: @clock.call)
        token = symbolize_keys(dispatch_token)
        return unless token[:kind] == :patrol_fix_semantic_admission

        source = source_for_token(token)
        return event_from_token(token, :stale, reason: "source_unavailable") unless source

        store_for(source, {}).cancel_unlaunched_decision!(
          token.fetch(:occurrence_id), reservation_id: token.fetch(:reservation_id), now: now
        )
        event_from_token(token, :cancelled, reason: "not_launched")
      rescue Hive::PatrolFix::AdmissionStore::StaleDecision
        event_from_token(token, :stale, reason: "reservation_changed")
      end

      private

      def process(source, entry, now:)
        occurrence_id = entry.fetch("occurrence_id")
        snapshot = Hive::PatrolFix::SourceSnapshot.new(entry.fetch("snapshot"))
        store = store_for(source, entry)
        record = store.fetch(occurrence_id) || store.reserve!(
          occurrence_id: occurrence_id, snapshot: snapshot, now: now
        )
        if record&.fetch("status") == "blocked"
          source.park!(occurrence_id: occurrence_id, now: now)
          return event(source, occurrence_id, :blocked, reason: "insufficient_evidence")
        end
        if record&.fetch("status") == "retry_wait"
          retry_at = Time.iso8601(record.dig("retry", "retry_at"))
          if retry_at > now
            source.defer!(occurrence_id: occurrence_id, retry_at: retry_at, now: now)
            return event(source, occurrence_id, :retry_wait, retry_at: retry_at)
          end
          if record.dig("retry", "reason") == "materialization_failure"
            record = store.resume_materialization_retry!(occurrence_id, now: now)
          end
        end

        unless recovery_without_capacity?(record) ||
               @capacity_available.call(source: source, entry: entry, record: record, now: now)
          return event(source, occurrence_id, :capacity_blocked, reason: "workflow_capacity")
        end

        if record&.fetch("status") == "deciding"
          expires_at = Time.iso8601(record.dig("decision_reservation", "expires_at"))
          if expires_at > now
            return event(source, occurrence_id, :decision_in_flight, retry_at: expires_at)
          end
          record = store.expire_decision!(occurrence_id, now: now)
        end

        unless record && %w[decided materializing bound acknowledged].include?(record.fetch("status"))
          begin
            semantic = require_factory!(@semantic_admission_factory, "semantic admission").call(
              store: store, source: source, entry: entry, snapshot: snapshot
            )
            reservation_id = decision_reservation_id(source, occurrence_id)
            record = semantic.prepare(
              occurrence_id: occurrence_id, snapshot: snapshot,
              reservation_id: reservation_id,
              lease_expires_at: now + DECISION_LEASE_SEC, now: now
            )
          rescue Hive::PatrolFix::AdmissionStore::StaleDecision
            return event(source, occurrence_id, :stale, reason: "candidate_digest_changed")
          rescue StandardError => error
            return defer_failure(
              source, store, occurrence_id, error, now: now,
              reason: "provider_failure"
            )
          end
          if record.fetch("status") == "deciding"
            token = dispatch_token(
              source, occurrence_id, record.dig("decision_reservation", "reservation_id")
            )
            return event(
              source, occurrence_id, :decision_dispatch,
              command: @semantic_command_factory.call(token), dispatch_token: token
            )
          end
        end

        if record.fetch("status") == "blocked"
          source.park!(occurrence_id: occurrence_id, now: now)
          return event(source, occurrence_id, :blocked, reason: "insufficient_evidence")
        end

        acknowledger = lambda do |_admission_record, binding|
          source.acknowledge!(
            occurrence_id: occurrence_id, admission_id: occurrence_id,
            task: binding, now: @clock.call
          )
        end
        begin
          materializer = require_factory!(@task_materializer_factory, "task materializer").call(
            store: store, source: source, entry: entry, snapshot: snapshot,
            source_acknowledger: acknowledger
          )
          result = materializer.call(occurrence_id)
        rescue StandardError => error
          return defer_failure(
            source, store, occurrence_id, error, now: now,
            reason: "materialization_failure"
          )
        end
        begin
          source.settle!(occurrence_id: occurrence_id, now: now)
        rescue StandardError => error
          return event(source, occurrence_id, :failed,
                       reason: "settlement_failure: #{error.class}: #{bounded_error(error)}")
        end
        event(source, occurrence_id, :acknowledged, task_slug: result.slug)
      rescue StandardError => error
        event(source, occurrence_id, :failed,
              reason: "#{error.class}: #{bounded_error(error)}")
      end

      def source_ports
        value = @sources.respond_to?(:call) ? @sources.call : @sources
        Array(value)
      end

      def store_for(source, entry)
        return @admission_store if @admission_store
        require_factory!(@admission_store_factory, "admission store").call(
          source: source, entry: entry
        )
      end

      def recovery_without_capacity?(record)
        record && %w[materializing bound acknowledged].include?(record.fetch("status"))
      end

      def default_retry_at(record, error, now)
        attempts = record&.dig("retry", "attempts").to_i
        normal = now + RETRY_BACKOFF_SEC.fetch([ attempts, RETRY_BACKOFF_SEC.length - 1 ].min)
        provider = provider_retry_at(error)
        provider && provider > normal ? provider : normal
      end

      def provider_retry_at(error)
        return unless error.respond_to?(:retry_at)
        value = error.retry_at
        value.is_a?(Time) ? value.utc : Time.iso8601(value.to_s).utc
      rescue ArgumentError
        nil
      end

      def defer_failure(source, store, occurrence_id, error, now:, reason:)
        retry_at = @retry_policy.call(store.fetch(occurrence_id), error, now)
        store.record_retry!(
          occurrence_id, reason: reason,
          error_class: error.class.name.to_s.empty? ? "StandardError" : error.class.name,
          retry_at: retry_at, now: now
        )
        source.defer!(occurrence_id: occurrence_id, retry_at: retry_at, now: now)
        event(source, occurrence_id, :retry_wait, retry_at: retry_at, reason: reason)
      end

      def decision_reservation_id(source, occurrence_id)
        Digest::SHA256.hexdigest(
          [ source.source, occurrence_id, SecureRandom.hex(32) ].join("\0")
        )
      end

      def dispatch_token(source, occurrence_id, reservation_id)
        project = source.respond_to?(:project) ? source.project.to_s : ""
        {
          kind: :patrol_fix_semantic_admission,
          project: project,
          source: source.source.to_s,
          occurrence_id: occurrence_id,
          reservation_id: reservation_id
        }.freeze
      end

      def semantic_command(token)
        project = token.fetch(:project)
        raise Hive::ConfigError, "Patrol Fix semantic admission project is unavailable" if project.empty?

        [
          "hive", "__patrol-fix-semantic-decision", project,
          "--source", token.fetch(:source),
          "--occurrence-id", token.fetch(:occurrence_id),
          "--reservation-id", token.fetch(:reservation_id), "--json"
        ].map { |value| Shellwords.escape(value.to_s) }.join(" ")
      end

      def symbolize_keys(value)
        value.to_h.each_with_object({}) { |(key, item), result| result[key.to_sym] = item }
      end

      def source_for_token(token)
        source_ports.find do |item|
          item.source.to_s == token.fetch(:source).to_s &&
            (!item.respond_to?(:project) || item.project.to_s == token.fetch(:project).to_s)
        end
      end

      def event_from_token(token, status, retry_at: nil, reason: nil)
        Event.new(
          source: token[:source], occurrence_id: token[:occurrence_id], status: status,
          task_slug: nil, retry_at: retry_at&.utc&.iso8601, reason: reason
        )
      end

      def require_factory!(factory, label)
        return factory if factory.respond_to?(:call)
        raise Hive::ConfigError, "Patrol Fix #{label} factory is unavailable"
      end

      def bounded_error(error)
        Hive::SecretPatterns.redact(error.message.to_s)[0, 256]
      end

      def event(source, occurrence_id, status, task_slug: nil, retry_at: nil, reason: nil,
                command: nil, dispatch_token: nil)
        Event.new(source: source.source, occurrence_id: occurrence_id,
                  status: status, task_slug: task_slug,
                  retry_at: retry_at&.utc&.iso8601, reason: reason,
                  command: command, dispatch_token: dispatch_token)
      end


      class CompletionFailure < StandardError
        attr_reader :retry_at, :error_class

        def initialize(envelope)
          value = envelope.is_a?(Hash) ? envelope : {}
          @retry_at = value["retry_at"]
          @error_class = value["error_class"].to_s
          @error_class = "SemanticDecisionChildError" if @error_class.empty?
          super(value["error"].to_s.empty? ? "semantic decision child failed" : value["error"])
        end
      end
    end
  end
end
