require "json"
require "hive/conditions/registry"
require "hive/conditions/value"
require "hive/conditions/policy"
require "hive/conditions/gate_evaluator"
require "hive/conditions/shadow_audit"
require "hive/stringify_keys"
require "hive/task_journal"
require "hive/work_ledger"

module Hive
  class TaskProjection
    SCHEMA = "hive-task-projection".freeze
    SCHEMA_VERSION = 1
    OPERATOR_ACTIONS_MAX = 20
    INVALID_HISTORY_REASON = "condition_task_history_invalid".freeze

    class Error < Hive::Error; end
    class InvalidJournal < Error; end
    class JournalLockBusy < Error; end

    # An unreadable journal is classified by the producer. Agent-authored
    # marker attributes cannot forge this control state.
    def self.history_invalid_row?(row)
      value = if row.respond_to?(:task_history_invalid)
        row.task_history_invalid
      elsif row.is_a?(Hash)
        row.key?(:task_history_invalid) ? row[:task_history_invalid] : row["task_history_invalid"]
      end
      value == true
    end

    def self.invalid_journal_marker_attrs(bounded:)
      diagnostic = bounded.diagnostics.first || {
        "reason" => "journal_unavailable",
        "message" => "task journal is unavailable",
        "details" => {}
      }
      reason = diagnostic.fetch("reason", "journal_unavailable").to_s
      attrs = {
        "reason" => INVALID_HISTORY_REASON,
        "owner" => "operator",
        "journal_reason" => reason[0, 128],
        "message" => diagnostic.fetch("message", "task journal is unavailable").to_s[0, 500]
      }
      attrs
    end

    def self.unavailable_journal_marker_attrs(bounded:)
      diagnostic = bounded.diagnostics.first || {}
      {
        "reason" => "condition_task_history_unavailable",
        "owner" => "scheduler",
        "journal_reason" => diagnostic.fetch("reason", "journal_unavailable").to_s[0, 128],
        "message" => diagnostic.fetch(
          "message", "task journal is temporarily unavailable"
        ).to_s[0, 500]
      }
    end

    INTERNAL_FACT_KEYS = %w[
      journal_index attempt_accepted_at predecessor_attempt_id
    ].freeze

    attr_reader :data

    def self.project(records:, cursor: nil, journal_hash: nil, marker: nil,
                     registry: Hive::Conditions::Registry.default)
      new(records: records, cursor: cursor, journal_hash: journal_hash,
          marker: marker, registry: registry).project
    end

    def self.read_journal(path)
      return [] unless File.exist?(path)

      replay_journal(File.binread(path)).records
    end

    def self.parse_journal(lines)
      bytes = lines.map { |line| line.end_with?("\n") ? line : "#{line}\n" }.join
      replay_journal(bytes).records
    end

    def self.replay_journal(bytes)
      validator = Hive::TaskJournal::Validator.new
      Hive::WorkLedger.replay(
        bytes: bytes,
        record_id: ->(record) { record["event_id"] },
        source_label: "journal",
        record_label: "event_id"
      ) do |record, line_number|
        unless record["schema"] == Hive::TaskJournal::Envelope::SCHEMA
          raise Hive::WorkLedger::InvalidRecord,
                "unexpected record schema #{record['schema'].inspect} at journal line #{line_number}"
        end
        validator.validate!(record)
        record
      rescue Hive::TaskJournal::Error => e
        raise Hive::WorkLedger::InvalidRecord,
              "invalid authoritative record at journal line #{line_number}: #{e.message}"
      end
    rescue Hive::WorkLedger::Error => e
      raise InvalidJournal, e.message
    end

    def self.canonical(value)
      case value
      when Hash
        value.keys.sort.to_h { |key| [ key.to_s, canonical(value[key]) ] }
      when Array then value.map { |child| canonical(child) }
      else value
      end
    end

    def self.canonical_json(value)
      JSON.generate(canonical(value))
    end

    def self.from_data(data)
      unless data.is_a?(Hash) && data["schema"] == SCHEMA && data["schema_version"] == SCHEMA_VERSION
        raise InvalidJournal, "invalid task projection envelope"
      end

      canonical_copy = JSON.parse(canonical_json(data))
      allocate.tap { |projection| projection.instance_variable_set(:@data, canonical_copy) }
    end

    def initialize(records:, cursor:, journal_hash:, marker:, registry:)
      @records = records.map { |record| Hive::StringifyKeys.call(record) }
      @cursor = cursor
      @journal_hash = journal_hash
      @marker = marker
      @registry = registry
    end

    def project
      facts = condition_facts
      generation = [
        facts.map { |fact| fact.fetch("task_generation") }.max,
        current_generation_from_events
      ].compact.max || 0
      commit_generation = current_commit_generation(generation)
      head_sha = current_head(generation, commit_generation)
      selected = select_current(facts, generation, commit_generation, head_sha)
      current = @registry.map do |definition|
        selected.fetch(definition.name) { pending_fact(definition, generation, commit_generation) }
      end
      history = facts.filter_map do |fact|
        next if selected[fact["condition"]].equal?(fact)

        replacement = selected[fact["condition"]] || family_replacement(fact, selected)
        supersede(fact, replacement, generation, commit_generation, head_sha)
      end

      authoritative = authoritative_records
      last = authoritative.last
      task = last&.fetch("task", nil) || facts.last&.fetch("task", nil)
      current_attempt = admitted_attempt_for(generation) ||
        current.reject { |fact| fact["state"] == "pending" }
               .max_by { |fact| fact.fetch("journal_index", -1) }
               &.fetch("attempt_id", nil)
      current_ownership = authoritative.reverse.find do |record|
        record["attempt_id"] == current_attempt && record["task_generation"] == generation
      end&.fetch("ownership_generation", nil)
      @data = self.class.canonical(
        "schema" => SCHEMA,
        "schema_version" => SCHEMA_VERSION,
        "journal" => {
          "cursor" => @cursor,
          "event_id" => last&.fetch("event_id", nil),
          "hash" => @journal_hash
        },
        "task" => task,
        "identity" => {
          "task_generation" => generation,
          "commit_generation" => commit_generation,
          "head_sha" => head_sha,
          "attempt_id" => current_attempt,
          "ownership_generation" => current_ownership
        },
        "conditions" => {
          "current" => current.map { |fact| public_fact(fact) },
          "history" => history.map { |fact| public_fact(fact) }
        },
        "evidence" => current.flat_map { |fact| fact["evidence"] }.uniq,
        "condition_overrides" => condition_overrides,
        "gates" => {},
        "provenance" => {
          "projector" => "TaskProjection/v#{SCHEMA_VERSION}",
          "authoritative_event_count" => authoritative.size,
          "legacy_event_count" => @records.size - authoritative.size
        },
        "compatibility" => legacy_compatibility(authoritative),
        "implementation_identity" => implementation_identity_projection(authoritative, generation),
        "shadow_audit" => Hive::Conditions::ShadowAudit.summary(records: authoritative)
      )
      rule = Hive::Conditions::Policy.default.rule_for("execute_to_open_pr")
      @data["gates"][rule.transition] = Hive::Conditions::GateEvaluator.new(
        projection: @data, rule: rule
      ).evaluate.to_h
      @data = self.class.canonical(@data)
      self
    end

    def to_h = Hive::StringifyKeys.call(@data || project.data)
    def [](key) = (@data || project.data)[key.to_s]

    def current_condition(name)
      self["conditions"].fetch("current").find { |fact| fact["condition"] == name.to_s }
    end

    # Compatibility markers remain a current-state input. Overlay their value
    # after folding history so status does not need another persisted cache.
    def with_marker(marker)
      copy = Hive::StringifyKeys.call(to_h)
      copy["compatibility"] = compatibility_for(
        baseline: copy.dig("compatibility", "baseline_present") == true,
        marker: marker
      )
      self.class.from_data(copy)
    end

    # Closure is a dedicated task-local authority, not a journal fact. Status
    # overlays its validated public receipt on a projection after replay so a
    # corrupt receipt can never alter condition or attempt truth.
    def with_closure(closure)
      copy = to_h
      copy["closure"] = Hive::StringifyKeys.call(closure)
      self.class.from_data(copy)
    end

    private

    def authoritative_records
      @authoritative_records ||= @records.select do |record|
        record["schema"] == Hive::TaskJournal::Envelope::SCHEMA
      end
    end

    def admitted_attempt_for(generation)
      authoritative_records.reverse_each do |record|
        next unless record["task_generation"] == generation
        next unless record["event_type"] == "activity_recorded"
        next unless record.dig("payload", "activity_kind") == "attempt_admitted"

        return record["attempt_id"]
      end
      nil
    end

    def condition_facts
      @condition_facts ||= authoritative_records.each_with_index.filter_map do |record, index|
        next unless record["event_type"] == "condition_observed"

        Hive::Conditions::Value.validate_observation!(record, registry: @registry)
        payload = record.fetch("payload")
        fact = {
          "condition" => payload.fetch("condition"),
          "state" => payload.fetch("state"),
          "reason" => record.fetch("reason"),
          "transitioned_at" => record.fetch("occurred_at"),
          "attempt_id" => record.fetch("attempt_id"),
          "task_generation" => record.fetch("task_generation"),
          "ownership_generation" => record["ownership_generation"],
          "commit_generation" => record["commit_generation"],
          "evidence" => Hive::StringifyKeys.call(record.fetch("evidence")),
          "provenance" => Hive::StringifyKeys.call(record.fetch("provenance")),
          "payload" => Hive::StringifyKeys.call(payload.reject { |key, _| %w[condition state].include?(key) }),
          "event_id" => record.fetch("event_id"),
          "task" => Hive::StringifyKeys.call(record["task"]),
          "journal_index" => index,
          "attempt_accepted_at" => record.dig("provenance", "attempt_accepted_at"),
          "predecessor_attempt_id" => record.dig("provenance", "predecessor_attempt_id")
        }
        fact
      end
    end

    def condition_overrides
      authoritative_records.select do |record|
        record["event_type"] == "operator_action"
      end.last(OPERATOR_ACTIONS_MAX).map do |record|
        payload = record.fetch("payload")
        {
          "event_id" => record.fetch("event_id"),
          "occurred_at" => record.fetch("occurred_at"),
          "attempt_id" => record.fetch("attempt_id"),
          "task_generation" => record.fetch("task_generation"),
          "commit_generation" => record["commit_generation"],
          "reason" => record.fetch("reason"),
          "transition" => payload["transition"],
          "from_stage" => payload["from_stage"],
          "to_stage" => payload["to_stage"],
          "source_command" => payload["source_command"],
          "waived_diagnostics" => Hive::StringifyKeys.call(payload.fetch("waived_diagnostics", [])),
          "provenance" => Hive::StringifyKeys.call(record.fetch("provenance"))
        }
      end
    end

    def current_generation_from_events
      authoritative_records.filter_map { |record| record["task_generation"] if record["task_generation"].is_a?(Integer) }.max || 0
    end

    def current_commit_generation(generation)
      authoritative_records.filter_map do |record|
        next unless record["task_generation"] == generation
        next unless record["commit_generation"].is_a?(Integer)

        record["commit_generation"]
      end.max || 0
    end

    def current_head(generation, commit_generation)
      candidates = authoritative_records.select do |record|
        record["task_generation"] == generation && record["commit_generation"] == commit_generation
      end
      candidates.reverse_each do |record|
        head = record.dig("payload", "head_sha") || record.dig("payload", "sha")
        return head if head
        commit = Array(record["evidence"]).reverse.find { |entry| entry["type"] == "commit" }
        return commit["sha"] if commit
      end
      nil
    end

    def select_current(facts, generation, commit_generation, head_sha)
      candidates = facts.select { |fact| fact["task_generation"] == generation }
      latest_attempt_by_family = candidates.group_by do |fact|
        family = @registry.fetch(fact["condition"]).supersession_family
        family
      end.transform_values do |facts_in_family|
        facts_in_family.max { |left, right| compare_attempt_precedence(left, right) }
                       .fetch("attempt_id")
      end

      eligible = candidates.select do |fact|
        definition = @registry.fetch(fact["condition"])
        next false unless latest_attempt_by_family[definition.supersession_family] == fact["attempt_id"]
        next true unless definition.scope == :commit
        next false unless fact["commit_generation"] == commit_generation
        next true unless head_sha
        # An explicit unverifiable observation is the current fail-closed
        # result when HEAD could not be observed. It deliberately has no
        # commit evidence; retaining the last known HEAD must not demote this
        # newer diagnostic to history and synthesize a misleading pending fact.
        next true if fact["state"] == "unverifiable" && commit_sha(fact).nil?

        commit_sha(fact) == head_sha
      end
      eligible.group_by { |fact| fact["condition"] }
              .transform_values { |group| group.max_by { |fact| fact["journal_index"] } }
    end

    def commit_sha(fact)
      fact.dig("payload", "head_sha") ||
        fact.fetch("evidence").reverse.find { |entry| entry["type"] == "commit" }&.fetch("sha", nil)
    end

    def compare_attempt_precedence(left, right)
      return left.fetch("journal_index") <=> right.fetch("journal_index") if left["attempt_id"] == right["attempt_id"]
      return 1 if attempt_descends_from?(left["attempt_id"], right["attempt_id"])
      return -1 if attempt_descends_from?(right["attempt_id"], left["attempt_id"])

      [ left["attempt_accepted_at"].to_s, left.fetch("journal_index") ] <=>
        [ right["attempt_accepted_at"].to_s, right.fetch("journal_index") ]
    end

    def attempt_descends_from?(candidate_id, ancestor_id)
      @attempt_predecessors ||= authoritative_records.each_with_object({}) do |record, predecessors|
        predecessor = record.dig("provenance", "predecessor_attempt_id")
        predecessors[record.fetch("attempt_id")] ||= predecessor unless predecessor.to_s.empty?
      end
      seen = {}
      current = candidate_id
      loop do
        predecessor = @attempt_predecessors[current]
        return false if predecessor.to_s.empty? || seen[predecessor]
        return true if predecessor == ancestor_id

        seen[predecessor] = true
        current = predecessor
      end
    end

    def public_fact(fact)
      fact.reject { |key, _| INTERNAL_FACT_KEYS.include?(key) }
    end

    def pending_fact(definition, generation, commit_generation)
      {
        "condition" => definition.name,
        "state" => "pending",
        "reason" => "no_current_observation",
        "transitioned_at" => nil,
        "attempt_id" => nil,
        "task_generation" => generation,
        "ownership_generation" => nil,
        "commit_generation" => definition.scope == :commit ? commit_generation : nil,
        "evidence" => [],
        "provenance" => { "source" => "projection", "synthetic_pending" => true },
        "payload" => {},
        "event_id" => nil,
        "journal_index" => -1
      }
    end

    def supersede(fact, replacement, generation, commit_generation, head_sha)
      reason = if fact["task_generation"] != generation
        "older_task_generation"
      elsif @registry.fetch(fact["condition"]).scope == :commit &&
            (fact["commit_generation"] != commit_generation || (head_sha && commit_sha(fact) != head_sha))
        "older_commit_generation"
      elsif replacement && replacement["attempt_id"] != fact["attempt_id"]
        "newer_incompatible_attempt"
      else
        "newer_observation"
      end
      Hive::StringifyKeys.call(fact).merge(
        "state" => "superseded",
        "original_state" => fact["state"],
        "superseded_reason" => reason,
        "superseded_by_event_id" => replacement&.fetch("event_id", nil)
      )
    end

    def family_replacement(fact, selected)
      family = @registry.fetch(fact["condition"]).supersession_family
      selected.values.select do |candidate|
        @registry.fetch(candidate["condition"]).supersession_family == family
      end.max_by { |candidate| candidate.fetch("journal_index") }
    end

    def legacy_compatibility(authoritative)
      baseline = authoritative.any? { |record| record["event_type"] == "legacy_baseline" }
      compatibility_for(baseline: baseline, marker: @marker)
    end

    def implementation_identity_projection(authoritative, generation)
      observations = authoritative.select do |record|
        record["event_type"] == "implementation_identity_observed"
      end.each_with_object({}) do |record, indexed|
        observation = projected_observation(record)
        indexed[[ observation.fetch("generation"), observation.fetch("stage") ]] =
          observation
      end
      identity_events = authoritative.select do |record|
        %w[implementation_identity_captured implementation_identity_backfilled
           implementation_stage_resolved].include?(record["event_type"])
      end
      execute_history = identity_events.filter_map do |record|
        next unless %w[implementation_identity_captured implementation_identity_backfilled]
                    .include?(record["event_type"])

        enrich_identity(projected_identity(record), observations)
      end
      execute = execute_history.reverse.find { |identity| identity["generation"] == generation }
      stages = identity_events.filter_map do |record|
        next unless record["event_type"] == "implementation_stage_resolved"

        identity = enrich_identity(projected_identity(record), observations)
        identity if identity["generation"] == generation
      end.group_by { |identity| identity.fetch("stage") }
       .transform_values(&:first)
      warnings = authoritative.filter_map do |record|
        next unless record["event_type"] == "implementation_identity_fallback"

        {
          "event_id" => record["event_id"],
          "generation" => record["task_generation"],
          "reason" => record["reason"]
        }
      end

      {
        "generation" => generation,
        "execute" => execute,
        "stages" => stages,
        "history" => execute_history,
        "fallback_warnings" => warnings
      }
    end

    def projected_identity(record)
      Hive::StringifyKeys.call(record.dig("payload", "identity") || {}).merge(
        "event_id" => record["event_id"],
        "resolved_attempt" => record["attempt_id"]
      )
    end

    def projected_observation(record)
      Hive::StringifyKeys.call(record.dig("payload", "observation") || {}).merge(
        "observation_event_id" => record["event_id"],
        "observed_attempt" => record["attempt_id"]
      )
    end

    def enrich_identity(identity, observations)
      observation = observations[[ identity.fetch("generation"), identity.fetch("stage") ]]
      return identity unless observation

      identity.merge(observation.reject { |key, _| %w[stage generation].include?(key) })
    end

    def compatibility_for(baseline:, marker:)
      marker = if marker
        {
          "name" => marker.respond_to?(:name) ? marker.name.to_s : marker.fetch("name").to_s,
          "attrs" => Hive::StringifyKeys.call(
            marker.respond_to?(:attrs) ? marker.attrs : marker.fetch("attrs", {})
          )
        }
      end
      {
        "baseline_present" => baseline,
        "marker" => marker,
        "marker_fallback" => baseline ? nil : marker
      }
    end
  end
end
