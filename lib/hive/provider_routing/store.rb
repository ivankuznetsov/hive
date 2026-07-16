require "json"
require "time"
require "hive/atomic_file"
require "hive/paths"
require "hive/provider_routing/circuit"

module Hive
  module ProviderRouting
    class Store
      SCHEMA_VERSION = 1
      Availability = Data.define(:status, :scope, :reason, :retry_at, :probe)
      Transition = Data.define(:provider, :model, :scope, :from, :to, :reason, :generation, :at)
      ProbeClaim = Data.define(:claimed, :provider, :model, :scope, :reason, :attempt_id)

      attr_reader :path, :lock_path

      def initialize(path: Hive::Paths.provider_circuits_path,
                     lock_path: nil, clock: -> { Time.now.utc })
        @path = path
        @lock_path = lock_path || "#{path}.lock"
        @clock = clock
      end

      def snapshot
        with_lock { deep_dup(read_snapshot_unlocked) }
      end

      def state(provider, model: nil)
        with_lock do
          snap = read_snapshot_unlocked
          deep_dup(circuit_at(snap, provider.to_s, model&.to_s) || Circuit.closed)
        end
      end

      def availability(provider:, model:, now: @clock.call)
        with_lock do
          snap = read_snapshot_unlocked
          provider_state = circuit_at(snap, provider.to_s, nil) || Circuit.closed
          provider_availability = availability_for(provider_state, scope: "provider", now: now)
          next provider_availability unless provider_availability.status == "closed"

          model_state = model && circuit_at(snap, provider.to_s, model.to_s)
          model_state ? availability_for(model_state, scope: "model", now: now) : provider_availability
        end
      end

      def record(signal, account:, now: @clock.call)
        return nil unless signal.circuit_worthy?

        result = mutate do |snap|
          model = signal.scope == "model" ? signal.model : nil
          before = circuit_at(snap, signal.provider, model) || Circuit.closed
          generation = next_generation!(snap)
          after = Circuit.open(
            state: before, signal: signal, account: account, now: now,
            generation: generation
          )
          set_circuit!(snap, signal.provider, model, after)
          [ transition(signal.provider, model, signal.scope, before, after, now), true ]
        end
        append_transition(result)
        result
      end

      def claim_probe(provider:, model:, attempt_id:, owner:, now: @clock.call)
        provider = provider.to_s
        model = model&.to_s
        result = mutate do |snap|
          scope, target_model, before = probe_target(snap, provider, model, now)
          unless before
            availability = availability_from_snapshot(snap, provider, model, now)
            next [ ProbeClaim.new(
              claimed: false, provider: provider, model: model, scope: availability.scope,
              reason: availability.reason || availability.status, attempt_id: attempt_id.to_s
            ), false ]
          end

          generation = next_generation!(snap)
          after = Circuit.claim_probe(
            state: before, attempt_id: attempt_id, owner: owner,
            now: now, generation: generation
          )
          set_circuit!(snap, provider, target_model, after)
          [ ProbeClaim.new(
            claimed: true, provider: provider, model: target_model, scope: scope,
            reason: before["reason"], attempt_id: attempt_id.to_s
          ), true ]
        end
        append_global_event(
          "event" => "probe_claim",
          "provider" => result.provider,
          "model" => result.model,
          "scope" => result.scope,
          "reason" => result.reason,
          "attempt_id" => result.attempt_id,
          "claimed" => result.claimed,
          "at" => now.utc.iso8601
        ) if result.claimed
        result
      end

      def probe_succeeded(provider:, model:, attempt_id:, now: @clock.call)
        complete_probe(provider: provider, model: model, attempt_id: attempt_id, now: now) do |snap, scope, target_model, before|
          generation = next_generation!(snap)
          after = Circuit.close(state: before, now: now, generation: generation)
          set_circuit!(snap, provider.to_s, target_model, after)
          [ transition(provider.to_s, target_model, scope, before, after, now), true ]
        end
      end

      def probe_failed(provider:, model:, attempt_id:, signal:, account:, now: @clock.call)
        complete_probe(provider: provider, model: model, attempt_id: attempt_id, now: now) do |snap, scope, target_model, before|
          generation = next_generation!(snap)
          after = Circuit.open(
            state: before, signal: signal, account: account, now: now,
            generation: generation, probe_failure: true
          )
          set_circuit!(snap, provider.to_s, target_model, after)
          [ transition(provider.to_s, target_model, scope, before, after, now), true ]
        end
      end

      # Roll back a probe reservation that never reached process spawn (for
      # example because the provider capacity lease lost a race). The circuit
      # remains open with its original retry evidence and can be claimed by a
      # later real attempt; the generation still advances for stale-writer
      # detection and observability.
      def abandon_probe(provider:, model:, attempt_id:, now: @clock.call)
        complete_probe(provider: provider, model: model, attempt_id: attempt_id, now: now) do |snap, scope, target_model, before|
          generation = next_generation!(snap)
          after = before.merge(
            "state" => "open",
            "generation" => generation,
            "last_transition_at" => now.utc.iso8601,
            "probe" => nil
          )
          set_circuit!(snap, provider.to_s, target_model, after)
          [ transition(provider.to_s, target_model, scope, before, after, now), true ]
        end
      end

      def clear(provider:, model: nil, reason:, actor: nil, now: @clock.call)
        provider = provider.to_s
        model = model&.to_s
        result = mutate do |snap|
          before = circuit_at(snap, provider, model)
          next [ nil, false ] unless before

          generation = next_generation!(snap)
          summary = [ reason.to_s.strip, actor && "actor=#{actor}" ].compact.join(" ")
          after = Circuit.close(state: before, now: now, generation: generation, reason: "manual_clear")
          after["safe_summary"] = summary[0, 160]
          set_circuit!(snap, provider, model, after)
          [ transition(provider, model, model ? "model" : "provider", before, after, now), true ]
        end
        append_transition(result, event: "manual_clear", actor: actor, summary: reason)
        result
      end

      private

      def complete_probe(provider:, model:, attempt_id:, now:)
        provider = provider.to_s
        model = model&.to_s
        result = mutate do |snap|
          located = locate_probe(snap, provider, model, attempt_id)
          next [ nil, false ] unless located

          scope, target_model, before = located
          yield snap, scope, target_model, before
        end
        append_transition(result)
        result
      end

      def append_transition(value, event: "circuit_transition", actor: nil, summary: nil)
        return unless value.is_a?(Transition)

        append_global_event(
          "event" => event,
          "provider" => value.provider,
          "model" => value.model,
          "scope" => value.scope,
          "from" => value.from,
          "to" => value.to,
          "reason" => value.reason,
          "generation" => value.generation,
          "actor" => actor&.to_s,
          "summary" => summary&.to_s&.slice(0, 160),
          "at" => value.at.utc.iso8601
        )
      end

      def append_global_event(record)
        path = Hive::Paths.provider_circuit_events_path
        FileUtils.mkdir_p(File.dirname(path))
        line = "#{JSON.generate(record.compact)}\n"
        File.open(path, File::WRONLY | File::APPEND | File::CREAT, 0o600) do |file|
          file.chmod(0o600)
          file.syswrite(line)
        end
      rescue SystemCallError, IOError => e
        warn "[hive.routing] failed to append circuit event: #{e.class}: #{e.message}"
        nil
      end

      def locate_probe(snap, provider, model, attempt_id)
        provider_state = circuit_at(snap, provider, nil)
        return [ "provider", nil, provider_state ] if provider_state && Circuit.probe_matches?(provider_state, attempt_id)

        model_state = model && circuit_at(snap, provider, model)
        return [ "model", model, model_state ] if model_state && Circuit.probe_matches?(model_state, attempt_id)

        nil
      end

      def probe_target(snap, provider, model, now)
        provider_state = circuit_at(snap, provider, nil)
        if provider_state && Circuit.probe_available?(provider_state, now: now)
          return [ "provider", nil, provider_state ]
        end
        return [ nil, nil, nil ] if provider_state && provider_state["state"] != "closed"

        model_state = model && circuit_at(snap, provider, model)
        if model_state && Circuit.probe_available?(model_state, now: now)
          return [ "model", model, model_state ]
        end

        [ nil, nil, nil ]
      end

      def availability_from_snapshot(snap, provider, model, now)
        provider_state = circuit_at(snap, provider, nil) || Circuit.closed
        result = availability_for(provider_state, scope: "provider", now: now)
        return result unless result.status == "closed"

        model_state = model && circuit_at(snap, provider, model)
        model_state ? availability_for(model_state, scope: "model", now: now) : result
      end

      def availability_for(state, scope:, now:)
        status = if Circuit.probe_available?(state, now: now)
          "probe_available"
        else
          state.fetch("state", "closed")
        end
        Availability.new(
          status: status,
          scope: scope,
          reason: state["reason"],
          retry_at: Circuit.parse_time(state["retry_at"]),
          probe: deep_dup(state["probe"])
        )
      end

      def transition(provider, model, scope, before, after, now)
        Transition.new(
          provider: provider,
          model: model,
          scope: scope,
          from: before.fetch("state"),
          to: after.fetch("state"),
          reason: after["reason"],
          generation: after.fetch("generation"),
          at: now.utc
        )
      end

      def circuit_at(snap, provider, model)
        entry = snap.dig("providers", provider)
        return nil unless entry

        model ? entry.dig("models", model) : entry["circuit"]
      end

      def set_circuit!(snap, provider, model, state)
        entry = (snap["providers"][provider] ||= { "circuit" => Circuit.closed, "models" => {} })
        if model
          entry["models"][model] = state
        else
          entry["circuit"] = state
        end
      end

      def next_generation!(snap)
        snap["generation"] = snap.fetch("generation", 0) + 1
      end

      def mutate
        with_lock do
          snap = read_snapshot_unlocked
          result, changed = yield snap
          write_snapshot_unlocked(snap) if changed
          result
        end
      end

      def with_lock
        FileUtils.mkdir_p(File.dirname(lock_path))
        File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
          lock.chmod(0o600)
          lock.flock(File::LOCK_EX)
          yield
        end
      rescue StoreError
        raise
      rescue SystemCallError, IOError => e
        raise StoreError, "provider circuit store at #{path} is unavailable: #{e.message}"
      end

      def read_snapshot_unlocked
        return empty_snapshot unless File.exist?(path)

        data = JSON.parse(File.read(path))
        unless data.is_a?(Hash) && data["schema_version"] == SCHEMA_VERSION && data["providers"].is_a?(Hash)
          raise StoreError,
                "provider circuit store at #{path} has unsupported or malformed schema; " \
                "preserving it unchanged"
        end
        data
      rescue JSON::ParserError, TypeError => e
        raise StoreError,
              "provider circuit store at #{path} is corrupt (#{e.message}); preserving it unchanged"
      rescue StoreError
        raise
      rescue SystemCallError, IOError => e
        raise StoreError, "provider circuit store at #{path} is unreadable: #{e.message}"
      end

      def write_snapshot_unlocked(snap)
        Hive::AtomicFile.write(path, JSON.pretty_generate(snap) + "\n", mode: 0o600)
        File.chmod(0o600, path)
      rescue SystemCallError, IOError => e
        raise StoreError, "provider circuit store at #{path} could not be written: #{e.message}"
      end

      def empty_snapshot
        { "schema_version" => SCHEMA_VERSION, "generation" => 0, "providers" => {} }
      end

      def deep_dup(value)
        case value
        when Hash then value.to_h { |key, child| [ key, deep_dup(child) ] }
        when Array then value.map { |child| deep_dup(child) }
        else value
        end
      end
    end
  end
end
