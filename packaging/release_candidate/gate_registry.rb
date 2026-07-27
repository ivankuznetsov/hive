# frozen_string_literal: true

require_relative "paths"

module HiveReleaseCandidate
  class GateRegistry
    Gate = Data.define(:name, :gate_class, :local, :default, :description) do
      def to_h
        {
          "name" => name,
          "class" => gate_class,
          "local" => local,
          "default" => default,
          "description" => description
        }
      end
    end

    GATES = [
      Gate.new(
        name: "artifact_integrity", gate_class: "blocking", local: true, default: true,
        description: "Verify every immutable candidate artifact against its manifest."
      ),
      Gate.new(
        name: "coverage_catalog", gate_class: "blocking", local: true, default: true,
        description: "Verify the U1 semantic release coverage catalog identity."
      ),
      Gate.new(
        name: "baseline_catalog", gate_class: "blocking", local: true, default: true,
        description: "Verify the reviewed release-baseline and offline-closure identity."
      ),
      Gate.new(
        name: "latest_stable_upgrade", gate_class: "blocking", local: true, default: true,
        description: "Prove the reviewed latest-stable state and channel upgrade survivor."
      ),
      Gate.new(
        name: "legacy_bench_v041_upgrade", gate_class: "blocking", local: true, default: true,
        description: "Prove the v0.4.1 producer/v0.4.2 observer bench migration survivor."
      ),
      Gate.new(
        name: "candidate_version", gate_class: "blocking", local: true, default: false,
        description: "Require the candidate version to be newer before release handoff."
      ),
      Gate.new(
        name: "trusted_remote_validation", gate_class: "blocking", local: false, default: false,
        description: "Reserved for the separately dispatched hosted validation workflow."
      )
    ].freeze

    def all
      GATES
    end

    def payload
      all.map(&:to_h)
    end

    def fetch(name)
      gate = all.find { |candidate| candidate.name == name.to_s }
      raise UsageError, "unknown candidate gate #{name.inspect}" unless gate

      gate
    end

    def local_defaults
      all.select { |gate| gate.local && gate.default }
    end

    def select_named(names)
      selected = names.map { |name| fetch(name) }
      unavailable = selected.reject(&:local)
      unless unavailable.empty?
        raise UnavailableError, "gate is not available locally: #{unavailable.map(&:name).join(', ')}"
      end
      selected.uniq(&:name)
    end

    def rerun(source:, mode:, names: [])
      effective = source.fetch("effective_gate_set", [])
      selected_names = case mode
      when "failed"
                         effective.select { |gate| gate["status"] == "failed" }.map { |gate| gate["name"] }
      when "missing"
                         proven = effective.map { |entry| entry["name"] }
                         local_defaults.map(&:name) - proven
      when "named"
                         names
      else
                         raise UsageError, "rerun requires exactly one selector mode"
      end
      raise UsageError, "rerun selector matched no eligible local gates" if selected_names.empty?

      select_named(selected_names)
    end
  end
end
