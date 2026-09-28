# frozen_string_literal: true

require "digest"
require "json"
require "time"
require "hive/errors"
require "hive/workflows"

module Hive
  # Closed catalog for the command mutations protected by durable command
  # receipts. This is intentionally not a repository-wide mutation registry:
  # adding a command family here is an explicit public-contract change.
  module CommandMutations
    MAX_KEY_BYTES = 512
    STAGE_VERBS = Hive::Workflows::VERBS.keys.freeze
    RECEIPT_MODES = %w[prune retire release-pin abandon-batch enroll].freeze

    Descriptor = Data.define(:command, :mode, :key_policy, :mutating, :semantic_options)

    CATALOG = {
      "new" => Descriptor.new(
        command: "new", mode: nil, key_policy: :optional, mutating: true,
        semantic_options: %i[text_sha256 slug body_sha256 base depends_on workflow attachments]
      ),
      "answer" => Descriptor.new(
        command: "answer", mode: "write", key_policy: :optional, mutating: true,
        semantic_options: %i[project binding binding_sha256 answer_sha256]
      ),
      "approve" => Descriptor.new(
        command: "approve", mode: nil, key_policy: :optional, mutating: true,
        semantic_options: %i[to from project force]
      ),
      "stage_action" => Descriptor.new(
        command: "stage_action", mode: nil, key_policy: :optional, mutating: true,
        semantic_options: %i[verb from project]
      ),
      "act" => Descriptor.new(
        command: "act", mode: nil, key_policy: :optional, mutating: true,
        semantic_options: %i[action_id observation project]
      ),
      "archive" => Descriptor.new(
        command: "archive", mode: "target", key_policy: :optional, mutating: true,
        semantic_options: %i[from project reason evidence_sha256 successor attestation_sha256]
      ),
      "receipt" => Descriptor.new(
        command: "receipt", mode: nil, key_policy: :forbidden, mutating: true,
        semantic_options: %i[
          namespace_id project confirm limit
        ]
      )
    }.freeze

    module_function

    def supported?(command:, target: nil, mode: nil, options: {})
      command = command.to_s
      return !(options[:binding] || options["binding"]).to_s.empty? if command == "answer"
      return !target.nil? && !target.to_s.empty? if command == "archive"
      return STAGE_VERBS.include?(mode.to_s) if command == "stage_action"
      return RECEIPT_MODES.include?(mode.to_s) if command == "receipt"

      CATALOG.key?(command)
    end

    def descriptor(command:, mode: nil)
      command = command.to_s
      unless supported?(command: command, target: command == "archive" ? "target" : nil,
                        mode: mode, options: command == "answer" ? { binding: "binding" } : {})
        raise Hive::UsageError, "unsupported keyed mutation: #{[ command, mode ].compact.join(' ')}"
      end

      base = CATALOG.fetch(command)
      return base unless command == "receipt"

      base.with(mode: mode.to_s, key_policy: mode.to_s == "prune" ? :optional : :forbidden)
    end

    def key_policy(command:, mode: nil)
      descriptor(command: command, mode: mode).key_policy
    end

    def validate_keyed!(command:, mode:, target:, options: {})
      command = command.to_s
      unless supported?(command: command, target: target, mode: mode, options: options)
        raise Hive::UsageError, "unsupported keyed mutation: #{[ command, mode ].compact.join(' ')}"
      end
      item = descriptor(command: command, mode: mode)
      if item.mode && item.mode != mode.to_s
        raise Hive::UsageError, "unsupported keyed mutation mode: #{command} #{mode}"
      end
      if key_policy(command: command, mode: mode) == :forbidden
        raise Hive::UsageError, "idempotency keys are forbidden for #{command} #{mode}".strip
      end
      unsupported = options.keys.map(&:to_sym).uniq - item.semantic_options
      unless unsupported.empty?
        raise Hive::UsageError,
              "unsupported keyed option(s) for #{command}: #{unsupported.sort.join(', ')}"
      end
      item
    end

    def normalize_key(value)
      key = value.to_s
      valid = value.is_a?(String) && key.encoding != Encoding::BINARY &&
        key.valid_encoding? && !key.empty? && key.bytesize <= MAX_KEY_BYTES
      return key.dup.freeze if valid

      raise Hive::UsageError,
            "--idempotency-key must be nonempty UTF-8 and at most #{MAX_KEY_BYTES} bytes"
    end

    def fingerprint(command:, namespace_id:, target:, principal:, options:, display: {})
      # Display-only options are deliberately not part of the semantic
      # fingerprint. Keep the argument to make that exclusion visible at call
      # sites and in contract tests.
      display
      payload = {
        "version" => 1,
        "command" => command.to_s,
        "namespace_id" => namespace_id.to_s,
        "target" => target.to_s,
        "principal" => principal.to_s,
        "options" => canonicalize(options)
      }
      Digest::SHA256.hexdigest(JSON.generate(canonicalize(payload)))
    end

    def canonicalize(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, item), result|
          result[key.to_s] = canonicalize(item)
        end.sort.to_h
      when Array
        value.map { |item| canonicalize(item) }
      when Symbol
        value.to_s
      when Time
        value.utc.iso8601(6)
      else
        value
      end
    end
    private_class_method :canonicalize
  end
end
