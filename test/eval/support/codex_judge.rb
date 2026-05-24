require "json"
require "open3"
require "timeout"

module Hive
  module Eval
    class CodexJudge
      Verdict = Struct.new(:pass, :score, :reason, :transcript, :model_used, :skipped, keyword_init: true)

      def initialize(rubric:, command: ENV.fetch("HIVE_CODEX_BIN", "codex"), timeout_sec: 120)
        @rubric = rubric
        @command = command
        @timeout_sec = timeout_sec
      end

      def verdict(text:)
        stdout, stderr, status = capture(prompt(text))
        transcript = [ stdout, stderr ].reject(&:empty?).join("\n")
        unless status.success?
          return Verdict.new(pass: false, score: 0,
                             reason: "judge_invocation_failed: #{stderr.to_s.strip[0, 500]}",
                             transcript: transcript, model_used: @command, skipped: false)
        end

        doc = parse_verdict(stdout)
        Verdict.new(
          pass: doc.fetch("pass") == true,
          score: Integer(doc.fetch("score")),
          reason: doc.fetch("reason").to_s,
          transcript: transcript,
          model_used: @command,
          skipped: false
        )
      rescue Timeout::Error
        Verdict.new(pass: false, score: 0, reason: "judge_invocation_failed: timeout",
                    transcript: "", model_used: @command, skipped: false)
      rescue StandardError => e
        Verdict.new(pass: false, score: 0,
                    reason: "judge_parse_failed: #{e.class}: #{e.message}",
                    transcript: transcript.to_s, model_used: @command, skipped: false)
      end

      private

      def capture(prompt)
        Timeout.timeout(@timeout_sec) do
          Open3.capture3(@command, "exec", "--json", prompt)
        end
      end

      def prompt(text)
        <<~PROMPT
          You are evaluating whether a Telegram bot's reply meets the rubric below.

          Rubric:
          #{@rubric}

          Reply to evaluate:
          #{text}

          Respond with a JSON object only:
          {"pass": true|false, "score": 0-5, "reason": "..."}
        PROMPT
      end

      def parse_verdict(stdout)
        agent_texts = stdout.to_s.lines.filter_map do |line|
          parse_json_line(line)&.dig("item", "text")
        end
        candidate = agent_texts.last || stdout
        JSON.parse(extract_json_object(candidate))
      end

      def parse_json_line(line)
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end

      def extract_json_object(text)
        body = text.to_s.strip
        body = body.delete_prefix("```json").delete_prefix("```").delete_suffix("```").strip
        return body if body.start_with?("{") && body.end_with?("}")

        match = body.match(/\{.*\}/m)
        raise JSON::ParserError, "no JSON object in judge output" unless match

        match[0]
      end
    end
  end
end
