require "digest"
require "json"
require "time"
require "uri"
require "hive"
require "hive/canonical_json"
require "hive/secret_patterns"

module Hive
  module Proposals
    RECORD_SCHEMA = "hive-proposal-record".freeze
    EVENT_SCHEMA = "hive-proposal-event".freeze
    SOURCE_EVENT_SCHEMA = "hive-proposal-source-event".freeze
    SCHEMA_VERSION = 1
    SUBJECT_KINDS = %w[skill workflow].freeze
    EVENT_TYPES = %w[evaluation decision supersession rollback].freeze
    STATUSES = %w[draft accepted rejected superseded rolled_back].freeze
    VISIBILITIES = %w[restricted private project].freeze
    RETENTIONS = %w[ephemeral task project indefinite].freeze
    RESULT_OUTCOMES = %w[pass fail mixed inconclusive].freeze
    EVALUATION_FACT_KEYS = %w[method result rationale evidence links].freeze
    EVALUATOR_CONFIG_KEYS = %w[workflows stages agent_profiles].freeze
    AUTHORITY_KINDS = %w[operator policy].freeze
    AUTHORITY_CAPABILITIES = %w[decide supersede rollback].freeze
    AUTHORITY_REQUIRED_KEYS = %w[kind capabilities version revoked].freeze
    AUTHORITY_OPTIONAL_KEYS = %w[valid_from valid_until].freeze
    DIGEST = /\A[0-9a-f]{64}\z/
    GIT_DIGEST = /\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
    PROPOSAL_ID = /\Aprp-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i
    EVENT_ID = /\Apev-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i
    SOURCE_EVENT_ID = /\Apse-[0-9a-f]{64}\z/
    SAFE_SUBJECT = /\A[A-Za-z0-9][A-Za-z0-9._\/-]{0,511}\z/
    SAFE_LABEL = /\A[^\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]{1,512}\z/
    FORBIDDEN_CONTROLS = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/
    MAX_TEXT_BYTES = 16 * 1024
    MAX_EVIDENCE_ITEMS = 64
    DEFAULT_POLICY = {
      "visibility" => "restricted", "retention" => "task",
      "allowed_link_schemes" => [ "https" ]
    }.freeze

    class Error < Hive::Error; end
    class InvalidRecord < Error
      def exit_code = Hive::ExitCodes::USAGE
    end
    class InvalidEvent < Error
      def exit_code = Hive::ExitCodes::USAGE
    end
    class Conflict < Error
      def exit_code = Hive::ExitCodes::USAGE
    end
    class InconsistentHistory < Error
      def exit_code = Hive::ExitCodes::USAGE
    end
    class QuotaExceeded < Error
      def exit_code = Hive::ExitCodes::TEMPFAIL
    end
    class Unauthorized < Error
      def exit_code = Hive::ExitCodes::USAGE
    end
    class StaleObservation < Error
      def exit_code = Hive::ExitCodes::TEMPFAIL
    end
    class QuarantinedSource < Error
      def exit_code = Hive::ExitCodes::USAGE
    end

    class SourceUnavailable < Error
      def exit_code = Hive::ExitCodes::TEMPFAIL
    end

    module_function

    def canonical(value) = Hive::CanonicalJSON.generate(value)
    def digest(value) = Hive::CanonicalJSON.digest(value)

    def deep_copy_freeze(value)
      copy = JSON.parse(JSON.generate(value))
      deep_freeze(copy)
    rescue JSON::GeneratorError, TypeError => e
      raise InvalidRecord, "proposal value is not JSON-safe: #{e.message}"
    end

    def deep_freeze(value)
      case value
      when Hash
        value.each { |key, child| key.freeze; deep_freeze(child) }
      when Array
        value.each { |child| deep_freeze(child) }
      end
      value.freeze
    end

    def stringify(value)
      Hive::CanonicalJSON.normalize(value)
    rescue TypeError => e
      raise InvalidRecord, "proposal value cannot be normalized: #{e.message}"
    end

    def closed_hash!(value, required:, optional: [], label:, error: InvalidRecord)
      value = stringify(value)
      raise error, "#{label} must be an object" unless value.is_a?(Hash)

      missing = required - value.keys
      unknown = value.keys - required - optional
      raise error, "#{label} missing fields: #{missing.join(', ')}" unless missing.empty?
      raise error, "#{label} has unknown fields: #{unknown.join(', ')}" unless unknown.empty?

      value
    end

    def text!(value, label:, max_bytes: MAX_TEXT_BYTES, allow_empty: false, error: InvalidRecord)
      text = Hive::SecretPatterns.redact(value.to_s)
      raise error, "#{label} contains a disallowed control character" if text.match?(FORBIDDEN_CONTROLS)
      raise error, "#{label} must be non-empty" if text.empty? && !allow_empty
      raise error, "#{label} exceeds #{max_bytes} bytes" if text.bytesize > max_bytes

      text
    end

    def label!(value, label:, error: InvalidRecord)
      text = text!(value, label:, max_bytes: 512, error:)
      raise error, "#{label} is malformed" unless text.match?(SAFE_LABEL)

      text
    end

    def subject_ref!(value, error: InvalidRecord)
      reference = value.to_s
      unless reference.match?(SAFE_SUBJECT) && reference.split("/").none? { |part| part == ".." }
        raise error, "proposal subject reference must be a safe project-relative reference"
      end
      reference
    end

    def proposal_id!(value, error: InvalidRecord)
      id = value.to_s
      raise error, "proposal id is malformed" unless id.match?(PROPOSAL_ID)
      id.downcase
    end

    def event_id!(value, error: InvalidEvent)
      id = value.to_s
      raise error, "proposal event id is malformed" unless id.match?(EVENT_ID)
      id.downcase
    end

    def source_event_id!(value, error: InvalidRecord)
      id = value.to_s
      raise error, "proposal source event id is malformed" unless id.match?(SOURCE_EVENT_ID)
      id
    end

    def digest!(value, label:, git: false, error: InvalidRecord)
      pattern = git ? GIT_DIGEST : DIGEST
      digest = value.to_s
      raise error, "#{label} must be a SHA digest" unless digest.match?(pattern)
      digest
    end

    def timestamp!(value, label:, error: InvalidRecord)
      time = value.is_a?(Time) ? value : Time.iso8601(value.to_s)
      time.utc.iso8601(6)
    rescue ArgumentError, TypeError
      raise error, "#{label} must be an ISO 8601 timestamp"
    end

    def policy!(value)
      raw = stringify(DEFAULT_POLICY.merge(stringify(value || {})))
      visibility = raw.fetch("visibility").to_s
      retention = raw.fetch("retention").to_s
      unless VISIBILITIES.include?(visibility) && RETENTIONS.include?(retention)
        raise InvalidRecord, "proposal evidence policy is malformed"
      end
      schemes = Array(raw.fetch("allowed_link_schemes", [ "https" ])).map(&:to_s).uniq.sort
      unless schemes.all? { |scheme| scheme.match?(/\A[a-z][a-z0-9+.-]*\z/) }
        raise InvalidRecord, "proposal allowed link schemes are malformed"
      end
      { "visibility" => visibility, "retention" => retention, "allowed_link_schemes" => schemes }
    end

    def effective_classification(requested, configured, vocabulary)
      request_index = requested.nil? ? 0 : vocabulary.index(requested.to_s)
      configured_index = vocabulary.index(configured.to_s)
      raise InvalidRecord, "proposal evidence classification is unknown" unless request_index && configured_index

      vocabulary[[ request_index, configured_index ].min]
    end

    def safe_reference!(value, label:, allowed_schemes: [ "https" ], error: InvalidRecord)
      reference = text!(value, label:, max_bytes: 2_048, error:)
      return reference if reference.match?(/\A[0-9a-f]{7,64}\z/i)
      return reference if reference.match?(SAFE_SUBJECT) &&
                          reference.split("/").none? { |part| part == ".." }

      uri = URI.parse(reference)
      unless uri.scheme && allowed_schemes.include?(uri.scheme.downcase) && uri.host && !uri.userinfo
        raise error, "#{label} uses a disallowed or malformed scheme"
      end
      reference
    rescue URI::InvalidURIError
      raise error, "#{label} uses a disallowed or malformed scheme"
    end

    def author!(value)
      data = closed_hash!(value, required: %w[id kind binding], label: "proposal author")
      data.each do |key, entry|
        data[key] = label!(entry, label: "proposal author #{key}")
      end
      data
    end

    def provenance!(value, error: InvalidRecord)
      required = %w[
        task_id task_generation ownership_generation attempt_id workflow_id stage actor source_commit
      ]
      optional = %w[
        configuration_fingerprint artifact_reference artifact_digest evaluator_binding
      ]
      data = closed_hash!(value, required:, optional:, label: "proposal provenance", error:)
      %w[task_id ownership_generation attempt_id workflow_id stage].each do |key|
        data[key] = label!(data[key], label: "proposal provenance #{key}", error:)
      end
      generation = data.fetch("task_generation")
      unless (generation.is_a?(Integer) && generation >= 0) ||
             (generation.is_a?(String) && !generation.empty?)
        raise error, "proposal provenance task_generation is malformed"
      end
      data["actor"] = actor!(data.fetch("actor"), error:)
      data["source_commit"] = digest!(data.fetch("source_commit"), label: "source_commit", git: true, error:)
      %w[configuration_fingerprint artifact_digest].each do |key|
        data[key] = digest!(data[key], label: key, error:) if data[key]
      end
      if data["artifact_reference"]
        data["artifact_reference"] = safe_reference!(
          data["artifact_reference"], label: "artifact_reference", error:
        )
      end
      if data["evaluator_binding"]
        binding = closed_hash!(
          data["evaluator_binding"], required: %w[id fingerprint],
          label: "evaluator binding", error:
        )
        binding["id"] = label!(binding["id"], label: "evaluator binding id", error:)
        binding["fingerprint"] = digest!(
          binding["fingerprint"], label: "evaluator binding fingerprint", error:
        )
        data["evaluator_binding"] = binding
      end
      data
    end

    def actor!(value, error: InvalidRecord)
      data = closed_hash!(
        value, required: %w[id kind], optional: %w[binding_fingerprint capability],
        label: "proposal actor", error:
      )
      %w[id kind capability].each do |key|
        data[key] = label!(data[key], label: "proposal actor #{key}", error:) if data[key]
      end
      if data["binding_fingerprint"]
        data["binding_fingerprint"] = digest!(
          data["binding_fingerprint"], label: "actor binding fingerprint", error:
        )
      end
      data
    end

    def evaluation_facts!(value, policy: DEFAULT_POLICY, error: InvalidEvent,
                          label: "proposal evaluation")
      policy = policy!(policy)
      data = closed_hash!(value, required: EVALUATION_FACT_KEYS, label:, error:)
      method = closed_hash!(
        data["method"], required: %w[kind label], optional: %w[reference],
        label: "#{label} method", error:
      )
      unless %w[benchmark test manual policy other].include?(method["kind"])
        raise error, "#{label} method kind is invalid"
      end
      method["label"] = label!(method["label"], label: "#{label} method label", error:)
      if method["reference"]
        method["reference"] = safe_reference!(
          method["reference"], label: "#{label} method reference",
          allowed_schemes: policy.fetch("allowed_link_schemes"), error:
        )
      end
      result = evaluation_result!(data["result"], label:, error:)
      data.merge(
        "method" => method, "result" => result,
        "rationale" => text!(data["rationale"], label: "#{label} rationale", error:),
        "evidence" => evidence!(data["evidence"], policy:, error:),
        "links" => links!(
          data["links"], allowed_schemes: policy.fetch("allowed_link_schemes"), error:
        )
      )
    end

    def evaluation_result!(value, label:, error: InvalidEvent)
      result = closed_hash!(
        value, required: %w[outcome metrics], optional: %w[details_digest],
        label: "#{label} result", error:
      )
      unless RESULT_OUTCOMES.include?(result["outcome"])
        raise error, "#{label} result outcome is invalid"
      end
      metrics = result["metrics"]
      unless metrics.is_a?(Hash) && metrics.length <= 64 && metrics.all? do |key, entry|
               key.to_s.match?(SAFE_LABEL) &&
                 (entry.nil? || [ true, false ].include?(entry) || entry.is_a?(Numeric))
             end
        raise error, "#{label} metrics must contain only bounded typed facts"
      end
      if result["details_digest"]
        result["details_digest"] = digest!(
          result["details_digest"], label: "#{label} details digest", error:
        )
      end
      result
    end

    def evidence!(items, policy: DEFAULT_POLICY, error: InvalidRecord)
      policy = policy!(policy)
      entries = Array(items)
      raise error, "proposal evidence exceeds #{MAX_EVIDENCE_ITEMS} items" if entries.length > MAX_EVIDENCE_ITEMS

      entries.map.with_index do |item, index|
        data = closed_hash!(
          item,
          required: %w[label media_type],
          optional: %w[content summary digest bytes visibility retention source_ref],
          label: "proposal evidence #{index}", error:
        )
        if data["retention"].is_a?(Hash)
          retention = closed_hash!(
            data["retention"], required: %w[policy enforcement],
            label: "proposal evidence retention", error:
          )
          unless RETENTIONS.include?(retention["policy"]) && retention["enforcement"] == "none" &&
                 VISIBILITIES.include?(data["visibility"])
            raise error, "proposal evidence persisted classification is invalid"
          end
          persisted = {
            "label" => label!(data["label"], label: "proposal evidence label", error:),
            "digest" => digest!(data["digest"], label: "proposal evidence digest", error:),
            "bytes" => data["bytes"],
            "media_type" => label!(data["media_type"], label: "proposal evidence media_type", error:),
            "visibility" => data["visibility"], "retention" => retention
          }
          unless persisted["bytes"].is_a?(Integer) && persisted["bytes"] >= 0
            raise error, "proposal evidence bytes must be a non-negative integer"
          end
          persisted["source_ref"] = safe_reference!(
            data["source_ref"], label: "proposal evidence source_ref",
            allowed_schemes: policy.fetch("allowed_link_schemes"), error:
          ) if data["source_ref"]
          if data["summary"]
            unless data["visibility"] == "project"
              raise error, "non-project evidence cannot persist a summary"
            end
            persisted["summary"] = text!(
              data["summary"], label: "proposal evidence summary", error:
            )
          end
          next persisted
        end
        content = data.delete("content") || data.delete("summary")
        content = text!(content, label: "proposal evidence content", error:) unless content.nil?
        digest = data["digest"] || (content && Digest::SHA256.hexdigest(content))
        raise error, "proposal evidence requires content or digest" unless digest
        bytes = data["bytes"] || content&.bytesize
        unless bytes.is_a?(Integer) && bytes >= 0
          raise error, "proposal evidence bytes must be a non-negative integer"
        end
        visibility = effective_classification(data["visibility"], policy.fetch("visibility"), VISIBILITIES)
        retention = effective_classification(data["retention"], policy.fetch("retention"), RETENTIONS)
        normalized = {
          "label" => label!(data["label"], label: "proposal evidence label", error:),
          "digest" => digest!(digest, label: "proposal evidence digest", error:),
          "bytes" => bytes,
          "media_type" => label!(data["media_type"], label: "proposal evidence media_type", error:),
          "visibility" => visibility,
          "retention" => { "policy" => retention, "enforcement" => "none" }
        }
        if data["source_ref"]
          normalized["source_ref"] = safe_reference!(
            data["source_ref"], label: "proposal evidence source_ref",
            allowed_schemes: policy.fetch("allowed_link_schemes"), error:
          )
        end
        normalized["summary"] = content if visibility == "project" && content
        normalized
      end
    end

    def links!(items, allowed_schemes: [ "https" ], error: InvalidEvent)
      Array(items).map do |item|
        data = item.is_a?(Hash) ? stringify(item) : { "kind" => "reference", "reference" => item }
        data = closed_hash!(data, required: %w[kind reference], label: "proposal link", error:)
        {
          "kind" => label!(data["kind"], label: "proposal link kind", error:),
          "reference" => safe_reference!(
            data["reference"], label: "proposal link reference", allowed_schemes:, error:
          )
        }
      end
    end
  end
end
