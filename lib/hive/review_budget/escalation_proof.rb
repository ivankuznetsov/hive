module Hive
  class ReviewBudget
    # Retain only hashes: operator answers may fill previously empty slots,
    # while question framing and already-answered decisions stay immutable.
    module EscalationProof
      ANSWER = /(^\s*###\s+A\d+\.)(.*?)(?=^\s*###\s+Q\d+\.|\z)/m
      CHECKBOX = /^(\s*-\s+)\[(x|\s*)\](\s+[^\n]*)/i

      module_function

      def capture(name, bytes)
        answers = []
        kind = "literal"
        framing = bytes.gsub(ANSWER) do
          kind = "qa"
          answer = Regexp.last_match(2)
          answers << { "digest" => Digest::SHA256.hexdigest(answer), "empty" => answer.strip.empty? }
          "#{Regexp.last_match(1)}<answer>"
        end
        if answers.empty?
          framing = bytes.gsub(CHECKBOX) do
            kind = "checkbox"
            checked = Regexp.last_match(2).casecmp?("x")
            answers << { "digest" => Digest::SHA256.hexdigest(checked ? "checked" : "empty"), "empty" => !checked }
            "#{Regexp.last_match(1)}[answer]#{Regexp.last_match(3)}"
          end
        end
        { "name" => name, "kind" => kind, "framing_digest" => Digest::SHA256.hexdigest(framing), "answers" => answers }
      end

      def valid?(proof)
        proof.is_a?(Hash) && proof.keys.sort == %w[answers framing_digest kind name] &&
          Hive::ReviewPass.prefix(proof["name"]) == "escalations" &&
          %w[qa checkbox literal].include?(proof["kind"]) && DIGEST.match?(proof["framing_digest"].to_s) &&
          proof["answers"].is_a?(Array) && proof["answers"].all? do |answer|
            answer.is_a?(Hash) && answer.keys.sort == %w[digest empty] &&
              DIGEST.match?(answer["digest"].to_s) && [ true, false ].include?(answer["empty"])
          end
      end

      def fills_only?(before, after)
        before.values_at("name", "kind", "framing_digest") == after.values_at("name", "kind", "framing_digest") &&
          before.fetch("answers").length == after.fetch("answers").length &&
          before.fetch("answers").zip(after.fetch("answers")).all? do |old, current|
            old == current || old.fetch("empty")
          end
      end
    end
  end
end
