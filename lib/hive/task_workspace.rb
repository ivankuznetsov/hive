require "json"
require "hive"
require "hive/task_workspace/source_error"
require "hive/task_workspace/limits"
require "hive/task_workspace/field"
require "hive/task_workspace/bounded_reader"

module Hive
  module TaskWorkspace
    SCHEMA = "hive-task-workspace".freeze
    SCHEMA_VERSION = 1
    SAFE_STRING_BYTES = 512 * 1024

    STATES = %w[
      current stale partial missing conflicting unavailable estimated exhausted retry-after
    ].freeze
    FRESHNESS_STATES = %w[fresh stale partial unavailable].freeze
    POSTURES = %w[wait answer approve retry investigate].freeze
    PANEL_NAMES = %w[
      provenance attempts resources timeline dependencies publication artifacts
    ].freeze
    SOURCES = %w[
      task_projection task_journal attempt_record controller_receipt agent_receipt
      runtime_receipt usage_db dependency_snapshot worktree_receipt local_git
      publication_cache github artifact event_stream current_observation legacy
      canonical_action status_snapshot operator bounded_reader workspace unknown
    ].freeze
    SOURCE_PRECEDENCE = SOURCES.each_with_index.to_h.freeze
    FORBIDDEN_KEYS = %w[
      capability capability_token observation_token raw_argv argv prompt prompts
      credential credentials secret secrets
    ].freeze

    module_function

    def canonical(value)
      case value
      when Hash
        value.keys.sort.to_h { |key| [ key.to_s, canonical(value[key]) ] }
      when Array
        value.map { |child| canonical(child) }
      else
        value
      end
    end

    def canonical_json(value)
      JSON.generate(canonical(value))
    end

    def safe_value!(value, path = [])
      case value
      when Hash
        value.each do |key, child|
          name = key.to_s
          if FORBIDDEN_KEYS.include?(name.downcase)
            raise ArgumentError, "forbidden workspace field #{(path + [ name ]).join('.')}"
          end
          if absolute_path_value?(name, child)
            raise ArgumentError, "absolute paths are forbidden in workspace snapshots"
          end
          safe_value!(child, path + [ name ])
        end
      when Array
        value.each_with_index { |child, index| safe_value!(child, path + [ index.to_s ]) }
      when String
        raise ArgumentError, "workspace string exceeds 512 KiB" if value.bytesize > SAFE_STRING_BYTES
      when NilClass, TrueClass, FalseClass, Numeric
        nil
      else
        raise ArgumentError, "unsupported workspace value #{value.class}"
      end
      value
    end

    def panel(name)
      raise ArgumentError, "unknown workspace panel #{name}" unless PANEL_NAMES.include?(name.to_s)

      value = yield
      value.is_a?(Hash) ? normalize_panel(name.to_s, value) : normalize_panel(
        name.to_s,
        "state" => Array(value).empty? ? "missing" : "current",
        "records" => Array(value), "diagnostics" => [], "truncated" => false
      )
    rescue SourceError => e
      normalize_panel(
        name.to_s,
        "state" => "unavailable", "records" => [],
        "diagnostics" => [ e.diagnostic ], "truncated" => false
      )
    rescue StandardError => e
      normalize_panel(
        name.to_s,
        "state" => "unavailable", "records" => [],
        "diagnostics" => [ {
          "source" => "workspace", "reason" => "source_error",
          "message" => Hive::SecretPatterns.redact(e.class.name), "details" => {}
        } ],
        "truncated" => false
      )
    end

    def normalize_panel(name, value)
      return unavailable_panel(name) if value.nil?

      panel = value.to_h.transform_keys(&:to_s)
      state = panel.fetch("state", Array(panel["records"]).empty? ? "missing" : "current").to_s
      raise ArgumentError, "invalid #{name} panel state" unless STATES.include?(state)

      normalized = {
        "state" => state,
        "records" => Array(panel["records"]),
        "diagnostics" => Array(panel["diagnostics"]),
        "truncated" => panel["truncated"] == true
      }
      panel.each do |key, child|
        normalized[key] = child unless normalized.key?(key)
      end
      safe_value!(normalized)
      canonical(normalized)
    end

    def unavailable_panel(name)
      {
        "state" => "unavailable",
        "records" => [],
        "diagnostics" => [ {
          "source" => "workspace",
          "reason" => "not_projected",
          "message" => "#{name} evidence is unavailable",
          "details" => {}
        } ],
        "truncated" => false
      }
    end

    def absolute_path_value?(key, value)
      return false unless value.is_a?(String)
      return false unless key.match?(/(?:path|root|folder|directory|evidence_ref)\z/i)

      value.start_with?("/", "\\") || value.match?(/\A[A-Za-z]:[\\\/]/)
    end
    private_class_method :absolute_path_value?
  end
end

require "hive/task_workspace/snapshot"
require "hive/task_workspace/semantic_snapshot"
