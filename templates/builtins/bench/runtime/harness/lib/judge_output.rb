# frozen_string_literal: true

require "json"

module HiveBench
  # Shared parsing of a judge model's reply. The rubric (judge-prompt.md) demands
  # ONLY a JSON object on the last line: {"score": <0-10>, "reason": "..."}.
  # Both the local-claude and the OpenRouter judges return free text, so both use
  # this to extract the score the same way: scan from the end for the last line
  # that parses to an object with a NUMERIC score (a null/non-numeric score is a
  # judge failure, never coerced into a real 0).
  module JudgeOutput
    class Error < StandardError; end

    module_function

    def parse_score(text)
      obj = last_score_object(text)
      raise Error, %(judge returned no parseable {"score": <number>} JSON) unless obj

      # `discussion` is only present in deliberation round-2 replies; empty
      # elsewhere. Passed through so the deliberation transcript keeps it.
      { score: obj["score"], reason: obj["reason"].to_s, discussion: obj["discussion"].to_s }
    end

    def last_score_object(text)
      text.to_s.lines.reverse_each do |line|
        candidate = line.strip[/\{.*\}/]
        next unless candidate

        begin
          obj = JSON.parse(candidate)
        rescue JSON::ParserError
          next
        end
        return obj if obj.is_a?(Hash) && obj["score"].is_a?(Numeric)
      end
      nil
    end
  end
end
