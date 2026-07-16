require "hive/agent_profiles"
require "hive/attempt_lease_store"
require "hive/provider_routing/request"
require "hive/provider_routing/decision"
require "hive/provider_routing/store"

module Hive
  module ProviderRouting
    class Router
      Outcome = Data.define(:transition, :exclusion)
      DispatchCheck = Data.define(:valid, :reason)

      attr_reader :circuit_store, :lease_store

      def initialize(circuit_store: Store.new, lease_store: Hive::AttemptLeaseStore.new,
                     clock: -> { Time.now.utc }, adapter_available: nil)
        @circuit_store = circuit_store
        @lease_store = lease_store
        @clock = clock
        @adapter_available = adapter_available || ->(name) { Hive::AgentProfiles.registered?(name) }
      end

      def select(request)
        configuration = request.configuration
        rejections = []
        candidates = pinned_candidates(configuration)

        candidates.each do |candidate|
          if (rejection = static_rejection(request, candidate))
            rejections << rejection
            next
          end

          account = configuration.accounts.fetch(candidate.provider)
          availability = @circuit_store.availability(
            provider: candidate.provider, model: candidate.model, now: @clock.call
          )
          probe = nil
          case availability.status
          when "closed"
            # continue to capacity claim
          when "probe_available"
            probe = @circuit_store.claim_probe(
              provider: candidate.provider,
              model: candidate.model,
              attempt_id: request.attempt_id,
              owner: owner_identity,
              now: @clock.call
            )
            unless probe.claimed
              rejections << rejection(candidate, "probe_claimed", probe.reason)
              next
            end
          else
            rejections << rejection(
              candidate,
              availability.status == "half_open" ? "probe_claimed" : "circuit_open",
              availability.reason || availability.status
            )
            next
          end

          claim = @lease_store.claim_provider(
            provider: candidate.provider,
            model: candidate.model,
            attempt_id: request.attempt_id,
            max_concurrent: account.max_concurrent,
            provenance: request.provenance.merge(
              "checkpoint" => request.checkpoint,
              "agent" => candidate.agent,
              "model" => candidate.model
            ),
            now: @clock.call
          )
          unless claim.claimed
            @circuit_store.abandon_probe(
              provider: candidate.provider, model: candidate.model,
              attempt_id: request.attempt_id, now: @clock.call
            ) if probe&.claimed
            rejections << rejection(candidate, "provider_cap", claim.reason)
            next
          end

          profile = request.profile_for(candidate.agent) ||
            Hive::AgentProfiles.lookup(candidate.agent, cfg: request.agent_config)
          return Decision.new(
            status: :selected,
            candidate: candidate,
            account: account,
            profile: profile,
            lease: claim.lease,
            probe: probe,
            attempt_id: request.attempt_id,
            reason: probe&.claimed ? "half_open_probe" : "first_eligible",
            wait_reason: nil,
            rejections: rejections,
            explanation: selection_explanation(candidate, probe)
          )
        end

        wait_decision(request, rejections)
      rescue StoreError, Hive::AttemptLeaseStoreError => e
        fail_closed_decision(request, rejections, e)
      end

      def record_outcome(decision:, success:, signal: nil, checkpoint: nil, now: @clock.call)
        return Outcome.new(transition: nil, exclusion: nil) unless decision&.selected?

        transition = if decision.probe?
          if success
            @circuit_store.probe_succeeded(
              provider: decision.provider,
              model: decision.model,
              attempt_id: decision.attempt_id,
              now: now
            )
          else
            probe_signal = signal&.circuit_worthy? ? signal : previous_probe_signal(decision)
            @circuit_store.probe_failed(
              provider: decision.provider,
              model: decision.model,
              attempt_id: decision.attempt_id,
              signal: probe_signal,
              account: decision.account,
              now: now
            )
          end
        elsif signal&.circuit_worthy?
          @circuit_store.record(signal, account: decision.account, now: now)
        end

        exclusion = if signal&.failure_class == "context_length"
          Request::Exclusion.new(
            provider: decision.provider,
            model: decision.model,
            checkpoint: checkpoint&.to_s,
            reason: "context_length"
          )
        end
        Outcome.new(transition: transition, exclusion: exclusion)
      ensure
        @lease_store.release(decision.lease, now: now) if decision&.lease
      end

      def cancel(decision, now: @clock.call)
        return false unless decision&.selected?

        @circuit_store.abandon_probe(
          provider: decision.provider,
          model: decision.model,
          attempt_id: decision.attempt_id,
          now: now
        ) if decision.probe?
        @lease_store.release(decision.lease, now: now)
      end

      def dispatch_valid?(decision, now: @clock.call)
        return DispatchCheck.new(valid: false, reason: "no_selected_decision") unless decision&.selected?
        unless @lease_store.active?(decision.lease, now: now)
          return DispatchCheck.new(valid: false, reason: "attempt_lease_inactive")
        end

        availability = @circuit_store.availability(
          provider: decision.provider,
          model: decision.model,
          now: now
        )
        if decision.probe?
          matches = availability.status == "half_open" &&
            availability.probe&.fetch("attempt_id", nil) == decision.attempt_id
          return DispatchCheck.new(valid: matches, reason: matches ? "probe_claim_valid" : "probe_claim_lost")
        end

        valid = availability.status == "closed"
        DispatchCheck.new(valid: valid, reason: valid ? "closed" : "circuit_no_longer_closed")
      rescue StoreError, Hive::AttemptLeaseStoreError => e
        DispatchCheck.new(valid: false, reason: "routing_state_unavailable: #{e.message}")
      end

      private

      def pinned_candidates(configuration)
        return configuration.pool unless configuration.pin

        configuration.pool.select do |candidate|
          candidate.provider == configuration.pin.provider &&
            (configuration.pin.model.nil? || candidate.model == configuration.pin.model)
        end
      end

      def static_rejection(request, candidate)
        unless request.profile_for(candidate.agent) || @adapter_available.call(candidate.agent)
          return rejection(candidate, "adapter_unavailable", candidate.agent)
        end
        return rejection(candidate, "context_excluded", request.checkpoint) if request.excluded?(candidate)

        requirements = request.configuration.required
        return rejection(candidate, "context_too_small", requirements.context) unless level_satisfied?(
          candidate.capabilities.fetch("context"), requirements.context, CONTEXT_LEVELS
        )
        return rejection(candidate, "quality_too_low", requirements.quality) unless level_satisfied?(
          candidate.capabilities.fetch("quality"), requirements.quality, QUALITY_LEVELS
        )

        missing_tools = requirements.tools - candidate.capabilities.fetch("tools")
        return rejection(candidate, "missing_tools", missing_tools.join(",")) unless missing_tools.empty?

        missing_permissions = requirements.permissions - candidate.capabilities.fetch("permissions")
        return rejection(candidate, "missing_permissions", missing_permissions.join(",")) unless missing_permissions.empty?

        nil
      end

      def level_satisfied?(actual, required, vocabulary)
        required.nil? || vocabulary.index(actual) >= vocabulary.index(required)
      end

      def rejection(candidate, reason, detail)
        Decision::Rejection.new(
          provider: candidate.provider,
          model: candidate.model,
          reason: reason,
          detail: detail.to_s
        )
      end

      def wait_decision(request, rejections)
        first = rejections.first
        constraint_reasons = %w[
          adapter_unavailable context_excluded context_too_small quality_too_low
          missing_tools missing_permissions
        ]
        wait_reason = if rejections.all? { |item| constraint_reasons.include?(item.reason) }
          "routing_constraints_unsatisfied"
        else
          "limits_reached"
        end
        Decision.new(
          status: :wait,
          attempt_id: request.attempt_id,
          reason: first&.reason || "no_candidates",
          wait_reason: wait_reason,
          rejections: rejections,
          explanation: first ? "#{first.provider}/#{first.model || 'default'}: #{first.reason}" : "no routing candidates"
        )
      end

      def fail_closed_decision(request, rejections, error)
        Decision.new(
          status: :wait,
          attempt_id: request.attempt_id,
          reason: "routing_state_unavailable",
          wait_reason: "limits_reached",
          rejections: rejections,
          explanation: error.message
        )
      end

      def selection_explanation(candidate, probe)
        suffix = probe&.claimed ? " as half-open probe" : ""
        "selected #{candidate.provider}/#{candidate.model || 'default'} via #{candidate.agent}#{suffix}"
      end

      def owner_identity
        "pid:#{Process.pid}:#{Hive::Lock.process_start_time(Process.pid)}"
      end

      def previous_probe_signal(decision)
        target_model = decision.probe.scope == "model" ? decision.model : nil
        state = @circuit_store.state(decision.provider, model: target_model)
        Signal.new(
          provider: decision.provider,
          model: target_model,
          failure_class: state.fetch("reason"),
          scope: decision.probe.scope,
          reset_at: nil,
          safe_summary: state["safe_summary"] || "half-open probe failed",
          fingerprint: state["fingerprint"],
          evidence_ref: state["evidence_ref"]
        )
      end
    end
  end
end
