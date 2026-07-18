require "json"
require "hive/conditions/registry"
require "hive/conditions/value"
require "hive/conditions/policy"
require "hive/conditions/gate_evaluator"
require "hive/conditions/shadow_audit"
require "hive/task_journal"

module Hive
  class TaskProjection
    SCHEMA = "hive-task-projection".freeze
    SCHEMA_VERSION = 1
    OPERATOR_ACTIONS_MAX = 20

    class Error < Hive::Error; end
    class InvalidJournal < Error; end

    INTERNAL_FACT_KEYS = %w[
      journal_index attempt_accepted_at durable_attempt_state
      durable_attempt_outcome durable_attempt_lease_version predecessor_attempt_id
    ].freeze

    attr_reader :data

    def self.project(records:, cursor: nil, journal_hash: nil, marker: nil,
                     registry: Hive::Conditions::Registry.default)
      new(records: records, cursor: cursor, journal_hash: journal_hash,
          marker: marker, registry: registry).project
    end

    def self.read_journal(path, attempt_store: nil)
      return [] unless File.exist?(path)

      parse_journal(File.readlines(path, chomp: true), attempt_store: attempt_store)
    end

    def self.parse_journal(lines, attempt_store: nil)
      seen = {}
      validator = Hive::TaskJournal::Validator.new(attempt_store: attempt_store)
      lines.filter_map.with_index do |line, index|
        next if line.empty?

        record = JSON.parse(line)
        unless record["schema"] == Hive::TaskJournal::Envelope::SCHEMA
          raise InvalidJournal,
                "unexpected record schema #{record['schema'].inspect} at journal line #{index + 1}"
        end
        validator.validate!(record)
        if (attempt = validator.attempt_for(record["attempt_id"]))
          record["__attempt"] = durable_attempt_metadata(attempt)
          record["__attempt_lineage"] = validator.lineage_for(record["attempt_id"]).map do |entry|
            durable_attempt_metadata(entry)
          end
        end
        event_id = record["event_id"]
        if event_id && seen[event_id]
          raise InvalidJournal, "duplicate event_id #{event_id.inspect} at journal line #{index + 1}"
        end
        seen[event_id] = true if event_id
        record
      rescue JSON::ParserError => e
        raise InvalidJournal, "invalid JSON at journal line #{index + 1}: #{e.message}"
      rescue Hive::TaskJournal::Error => e
        raise InvalidJournal, "invalid authoritative record at journal line #{index + 1}: #{e.message}"
      end
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

    def self.durable_attempt_metadata(attempt)
      task_generation = attempt.respond_to?(:task_input_epoch) ? attempt.task_input_epoch : attempt["task_input_epoch"]
      ownership_generation = if attempt.respond_to?(:ownership_generation)
        attempt.ownership_generation
      else
        attempt["ownership_generation"]
      end
      lease_version = attempt.respond_to?(:lease_version) ? attempt.lease_version : attempt["lease_version"]

      {
        "attempt_id" => attempt["attempt_id"],
        "task" => { "id" => attempt["task_id"]&.to_s, "slug" => attempt["task_slug"] },
        "stage" => attempt["intended_stage"],
        "task_generation" => task_generation,
        "ownership_generation" => ownership_generation,
        "accepted_at" => attempt["accepted_at"],
        "predecessor_attempt_id" => attempt["predecessor_attempt_id"],
        "state" => attempt.respond_to?(:state) ? attempt.state : attempt["state"],
        "outcome" => attempt.respond_to?(:outcome) ? attempt.outcome : attempt["outcome"],
        "lease_version" => lease_version
      }
    end

    def self.from_data(data)
      unless data.is_a?(Hash) && data["schema"] == SCHEMA && data["schema_version"] == SCHEMA_VERSION
        raise InvalidJournal, "invalid task projection snapshot envelope"
      end

      canonical_copy = JSON.parse(canonical_json(data))
      allocate.tap { |projection| projection.instance_variable_set(:@data, canonical_copy) }
    end

    def initialize(records:, cursor:, journal_hash:, marker:, registry:)
      @records = records.map { |record| deep_copy(record) }
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
      current_attempt = current.reject { |fact| fact["state"] == "pending" }
                               .max_by { |fact| fact.fetch("journal_index", -1) }
                               &.fetch("attempt_id", nil)
      @data = self.class.canonical(
        "schema" => SCHEMA,
        "schema_version" => SCHEMA_VERSION,
        "journal" => {
          "cursor" => @cursor,
          "event_id" => last&.fetch("event_id", nil),
          "hash" => @journal_hash,
          "attempts" => journal_attempt_bindings
        },
        "task" => task,
        "identity" => {
          "task_generation" => generation,
          "commit_generation" => commit_generation,
          "head_sha" => head_sha,
          "attempt_id" => current_attempt
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

    def to_h = deep_copy(@data || project.data)
    def [](key) = (@data || project.data)[key.to_s]

    def current_condition(name)
      self["conditions"].fetch("current").find { |fact| fact["condition"] == name.to_s }
    end

    # Compatibility markers are written after snapshot publication. Overlay
    # the currently observed marker in memory so status can consume a valid
    # snapshot without republishing it or classifying markers outside this
    # projection boundary.
    def with_marker(marker)
      copy = deep_copy(to_h)
      copy["compatibility"] = compatibility_for(
        baseline: copy.dig("compatibility", "baseline_present") == true,
        marker: marker
      )
      self.class.from_data(copy)
    end

    private

    def authoritative_records
      @authoritative_records ||= @records.select do |record|
        record["schema"] == Hive::TaskJournal::Envelope::SCHEMA
      end
    end

    def journal_attempt_bindings
      @journal_attempt_bindings ||= authoritative_records.flat_map do |record|
        record.fetch("__attempt_lineage", [])
      end.uniq { |binding| binding.fetch("attempt_id") }
        .sort_by { |binding| binding.fetch("attempt_id") }
        .map { |binding| deep_copy(binding) }
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
          "evidence" => deep_copy(record.fetch("evidence")),
          "provenance" => deep_copy(record.fetch("provenance")),
          "payload" => deep_copy(payload.reject { |key, _| %w[condition state].include?(key) }),
          "event_id" => record.fetch("event_id"),
          "task" => deep_copy(record["task"]),
          "journal_index" => index,
          "attempt_accepted_at" => record.dig("__attempt", "accepted_at") ||
            record.dig("provenance", "attempt_accepted_at"),
          "predecessor_attempt_id" => record.dig("__attempt", "predecessor_attempt_id") ||
            record.dig("provenance", "predecessor_attempt_id"),
          "durable_attempt_state" => record.dig("__attempt", "state"),
          "durable_attempt_outcome" => record.dig("__attempt", "outcome"),
          "durable_attempt_lease_version" => record.dig("__attempt", "lease_version")
        }
        reconcile_durable_agent_health(fact)
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
          "waived_diagnostics" => deep_copy(payload.fetch("waived_diagnostics", [])),
          "provenance" => deep_copy(record.fetch("provenance"))
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
      @attempt_predecessors ||= journal_attempt_bindings.to_h do |binding|
        [ binding.fetch("attempt_id"), binding["predecessor_attempt_id"] ]
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

    def reconcile_durable_agent_health(fact)
      return fact unless fact["condition"] == "AgentHealthy"

      durable_state = fact["durable_attempt_state"]
      return fact unless %w[terminal lost].include?(durable_state)

      durable_outcome = fact["durable_attempt_outcome"]
      state, reason = if durable_state == "lost"
        [ "unsatisfied", "attempt_lost" ]
      elsif durable_outcome == "succeeded"
        [ "satisfied", "attempt_terminal_succeeded" ]
      else
        [ "unsatisfied", "attempt_terminal_#{durable_outcome || 'unknown'}" ]
      end
      durable_evidence = {
        "type" => "attempt_lease",
        "attempt_id" => fact["attempt_id"],
        "lease_version" => fact["durable_attempt_lease_version"],
        "state" => durable_state,
        "outcome" => durable_outcome
      }
      fact.merge(
        "state" => state,
        "reason" => reason,
        "evidence" => (fact.fetch("evidence") + [ durable_evidence ]).uniq,
        "provenance" => fact.fetch("provenance").merge(
          "projection_reconciled_attempt_state" => true
        ),
        "payload" => fact.fetch("payload").merge(
          "informational_after_terminal" => durable_state == "terminal" && state == "satisfied"
        )
      )
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
      deep_copy(fact).merge(
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
      identity_events = authoritative.select do |record|
        %w[implementation_identity_captured implementation_identity_backfilled
           implementation_stage_resolved].include?(record["event_type"])
      end
      execute_history = identity_events.filter_map do |record|
        next unless %w[implementation_identity_captured implementation_identity_backfilled]
                    .include?(record["event_type"])

        projected_identity(record)
      end
      execute = execute_history.reverse.find { |identity| identity["generation"] == generation }
      stages = identity_events.filter_map do |record|
        next unless record["event_type"] == "implementation_stage_resolved"

        identity = projected_identity(record)
        identity if identity["generation"] == generation
      end.group_by { |identity| identity.fetch("stage") }
       .transform_values(&:last)
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
      deep_copy(record.dig("payload", "identity") || {}).merge(
        "event_id" => record["event_id"],
        "resolved_attempt" => record["attempt_id"]
      )
    end

    def compatibility_for(baseline:, marker:)
      marker = if marker
        {
          "name" => marker.respond_to?(:name) ? marker.name.to_s : marker.fetch("name").to_s,
          "attrs" => deep_copy(marker.respond_to?(:attrs) ? marker.attrs : marker.fetch("attrs", {}))
        }
      end
      {
        "baseline_present" => baseline,
        "marker" => marker,
        "marker_fallback" => baseline ? nil : marker
      }
    end

    def deep_copy(value)
      case value
      when Hash then value.to_h { |key, child| [ key.to_s, deep_copy(child) ] }
      when Array then value.map { |child| deep_copy(child) }
      else value
      end
    end
  end
end
