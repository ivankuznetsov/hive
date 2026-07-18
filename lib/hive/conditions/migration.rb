require "hive/conditions/gate_evaluator"
require "hive/task_projection"
require "hive/task_journal"

module Hive
  module Conditions
    class InvalidMigrationMode < Hive::Error; end

    ModeSelection = Data.define(:configured, :effective, :handoff_complete, :authority_capable) do
      def to_h
        {
          "configured" => configured,
          "effective" => effective,
          "handoff_complete" => handoff_complete,
          "authority_capable" => authority_capable
        }
      end
    end

    module Migration
      MODES = %w[markers shadow conditions].freeze
      CONDITION_AUTHORITY_STAGES = [ "4-execute" ].freeze # coding-scoped: increment 1 enables coding execute only

      module_function

      def configured_mode(config, stage)
        settings = config.fetch("conditions", {})
        overrides = settings.fetch("stages", {})
        explicit = overrides.key?(stage.to_s)
        mode = overrides.fetch(stage.to_s, settings.fetch("authority", "markers")).to_s
        mode = "markers" if !explicit && !CONDITION_AUTHORITY_STAGES.include?(stage.to_s)
        validate_mode!(mode, stage)
        mode
      end

      def selection(config:, stage:, projection:, rule: nil, registry: Hive::Conditions::Registry.default)
        configured = configured_mode(config, stage)
        data = projection.respond_to?(:to_h) ? projection.to_h : projection
        attempt_id = data.dig("identity", "attempt_id") ||
                     data.dig("journal", "attempts")&.last&.fetch("attempt_id", nil) ||
                     data.dig("compatibility", "marker", "attrs", "attempt_id") ||
                     data.dig("compatibility", "marker_fallback", "attrs", "attempt_id")
        handoff = !attempt_id.to_s.empty? && attempt_id != Hive::TaskJournal::LEGACY_ATTEMPT_ID
        capable = authority_capable?(rule: rule, stage: stage, registry: registry)
        effective = handoff && capable ? configured : "markers"
        ModeSelection.new(
          configured: configured, effective: effective,
          handoff_complete: handoff, authority_capable: capable
        )
      end

      def authority_capable?(rule:, stage:, registry: Hive::Conditions::Registry.default)
        return true unless rule
        return false unless rule.authoritative_capable

        (rule.required + rule.inhibitors).all? do |name|
          registry.fetch(name).authoritative_for?(stage)
        end
      end

      def validate_mode!(mode, stage)
        raise InvalidMigrationMode, "unknown condition authority mode #{mode.inspect}" unless MODES.include?(mode)
        if mode == "conditions" && !CONDITION_AUTHORITY_STAGES.include?(stage.to_s)
          raise InvalidMigrationMode,
                "condition authority is not enabled for stage #{stage.inspect} in increment 1"
        end
        mode
      end

      def ensure_legacy_baseline!(task:, writer:, marker:, head_sha:, branch:, workflow: "coding")
        records = Hive::TaskProjection.read_journal(writer.path, attempt_store: writer.attempt_store)
        existing = records.find { |record| record["event_type"] == "legacy_baseline" }
        return existing if existing

        fallback = Hive::TaskProjection.project(records: records, marker: marker)
                                      .to_h.dig("compatibility", "marker_fallback")
        writer.append(
          event_type: "legacy_baseline",
          task: {
            "id" => task.respond_to?(:id) ? task.id&.to_s : nil,
            "slug" => task.slug.to_s
          },
          workflow: workflow,
          stage: "4-execute", # coding-scoped: legacy baselines are introduced at the coding execute boundary
          attempt_id: Hive::TaskJournal::LEGACY_ATTEMPT_ID,
          task_generation: 0,
          commit_generation: 0,
          reason: "legacy_marker_import",
          evidence: head_sha ? [ { "type" => "commit", "sha" => head_sha, "branch" => branch } ] : [],
          provenance: { "source" => "legacy_migration", "synthetic" => false },
          payload: {
            "legacy_marker" => fallback,
            "head_sha" => head_sha,
            "branch" => branch
          }
        )
      end
    end
  end
end
