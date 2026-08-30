# frozen_string_literal: true

require "digest"
require "json"
require "hive/brainstorm_suggestions"

module Hive
  module BrainstormSuggestions
    # Stable freshness identities. Only admitted selected entries participate
    # in the input binding; repository-global diagnostics such as HEAD do not.
    module Binding
      VERSION = 1
      INPUT_DOMAIN = "hive-brainstorm-suggestion-input-v1"
      SUGGESTION_DOMAIN = "hive-brainstorm-suggestion-candidate-v1"

      module_function

      def input(task_incarnation:, task_generation:, brainstorm_generation:,
                question_identity:, question_text:, manifest:, settled_answers:)
        selected_manifest = {
          "recipe" => fetch(manifest, "recipe"),
          "recipe_version" => fetch(manifest, "recipe_version"),
          "entries" => Array(fetch(manifest, "entries")).map do |entry|
            {
              "path" => fetch(entry, "path"),
              "mode" => fetch(entry, "mode"),
              "digest" => fetch(entry, "digest"),
              "source" => fetch(entry, "source")
            }
          end
        }
        digest(
          "domain" => INPUT_DOMAIN,
          "version" => VERSION,
          "task_incarnation" => task_incarnation.to_s,
          "task_generation" => task_generation,
          "brainstorm_generation" => brainstorm_generation,
          "question_identity" => question_identity.to_s,
          "question_text" => question_text.to_s.scrub,
          "manifest" => selected_manifest,
          "settled_answers" => Array(settled_answers)
        )
      end

      def suggestion(input_binding:, attempt_id:, candidate_id:)
        digest(
          "domain" => SUGGESTION_DOMAIN,
          "version" => VERSION,
          "input_binding" => input_binding.to_s,
          "attempt_id" => attempt_id.to_s,
          "candidate_id" => candidate_id.to_s
        )
      end

      def digest(value)
        Digest::SHA256.hexdigest(JSON.generate(canonical(value)))
      end

      def canonical(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, item), out|
            out[key.to_s] = canonical(item)
          end.sort.to_h
        when Array
          value.map { |item| canonical(item) }
        when String
          value.scrub.unicode_normalize(:nfc)
        when Integer, Float, TrueClass, FalseClass, NilClass
          value
        else
          value.to_s
        end
      end
      private_class_method :canonical

      def fetch(hash, key)
        return hash.fetch(key) if hash.key?(key)

        hash.fetch(key.to_sym)
      end
      private_class_method :fetch
    end
  end
end
