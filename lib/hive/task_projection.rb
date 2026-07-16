require "json"
require "hive/conditions/registry"
require "hive/conditions/value"
require "hive/task_journal/envelope"

module Hive
  class TaskProjection
    SCHEMA = "hive-task-projection".freeze
    SCHEMA_VERSION = 1

    class Error < Hive::Error; end
    class InvalidJournal < Error; end

    attr_reader :data

    def self.project(records:, cursor: nil, journal_hash: nil, marker: nil,
                     registry: Hive::Conditions::Registry.default)
      new(records: records, cursor: cursor, journal_hash: journal_hash,
          marker: marker, registry: registry).project
    end

    def self.read_journal(path)
      return [] unless File.exist?(path)

      seen = {}
      File.readlines(path, chomp: true).filter_map.with_index do |line, index|
        next if line.empty?

        record = JSON.parse(line)
        event_id = record["event_id"]
        if event_id && seen[event_id]
          raise InvalidJournal, "duplicate event_id #{event_id.inspect} at journal line #{index + 1}"
        end
        seen[event_id] = true if event_id
        record
      rescue JSON::ParserError => e
        raise InvalidJournal, "invalid JSON at journal line #{index + 1}: #{e.message}"
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
          "hash" => @journal_hash
        },
        "task" => task,
        "identity" => {
          "task_generation" => generation,
          "commit_generation" => commit_generation,
          "head_sha" => head_sha,
          "attempt_id" => current_attempt
        },
        "conditions" => {
          "current" => current.map { |fact| fact.reject { |key, _| key == "journal_index" } },
          "history" => history.map { |fact| fact.reject { |key, _| key == "journal_index" } }
        },
        "evidence" => current.flat_map { |fact| fact["evidence"] }.uniq,
        "gates" => {},
        "provenance" => {
          "projector" => "TaskProjection/v#{SCHEMA_VERSION}",
          "authoritative_event_count" => authoritative.size,
          "legacy_event_count" => @records.size - authoritative.size
        },
        "compatibility" => legacy_compatibility(authoritative)
      )
      self
    end

    def to_h = deep_copy(@data || project.data)
    def [](key) = (@data || project.data)[key.to_s]

    def current_condition(name)
      self["conditions"].fetch("current").find { |fact| fact["condition"] == name.to_s }
    end

    private

    def authoritative_records
      @authoritative_records ||= @records.select do |record|
        record["schema"] == Hive::TaskJournal::Envelope::SCHEMA
      end
    end

    def condition_facts
      @condition_facts ||= authoritative_records.each_with_index.filter_map do |record, index|
        next unless record["event_type"] == "condition_observed"

        Hive::Conditions::Value.validate_observation!(record, registry: @registry)
        payload = record.fetch("payload")
        {
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
          "journal_index" => index
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
      latest_attempt_by_family = {}
      candidates.each do |fact|
        family = @registry.fetch(fact["condition"]).supersession_family
        latest_attempt_by_family[family] = fact["attempt_id"]
      end

      eligible = candidates.select do |fact|
        definition = @registry.fetch(fact["condition"])
        next false unless latest_attempt_by_family[definition.supersession_family] == fact["attempt_id"]
        next true unless definition.scope == :commit
        next false unless fact["commit_generation"] == commit_generation
        next true unless head_sha

        commit_sha(fact) == head_sha
      end
      eligible.group_by { |fact| fact["condition"] }
              .transform_values { |group| group.max_by { |fact| fact["journal_index"] } }
    end

    def commit_sha(fact)
      fact.dig("payload", "head_sha") ||
        fact.fetch("evidence").reverse.find { |entry| entry["type"] == "commit" }&.fetch("sha", nil)
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
      marker = if @marker
        {
          "name" => @marker.respond_to?(:name) ? @marker.name.to_s : @marker.fetch("name").to_s,
          "attrs" => deep_copy(@marker.respond_to?(:attrs) ? @marker.attrs : @marker.fetch("attrs", {}))
        }
      end
      { "baseline_present" => baseline, "marker_fallback" => baseline ? nil : marker }
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
