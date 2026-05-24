require "json"
require "open3"
require "timeout"

module Hive
  module Eval
    class ScriptedPersona
      def initialize(replies:)
        @replies = replies.dup
      end

      def respond(bot_message:)
        raise "scripted persona has no replies left for #{bot_message.inspect}" if @replies.empty?

        @replies.shift
      end
    end

    class CodexPersona
      def initialize(role_prompt:, command: ENV.fetch("HIVE_CODEX_BIN", "codex"), timeout_sec: 120)
        @role_prompt = role_prompt
        @command = command
        @timeout_sec = timeout_sec
      end

      def respond(bot_message:)
        stdout, stderr, status = capture(prompt(bot_message))
        raise "codex persona failed: #{stderr.strip}" unless status.success?

        reply = parse_reply(stdout)
        raise "codex persona returned an empty reply" if reply.strip.empty?

        reply
      end

      private

      def capture(prompt)
        Timeout.timeout(@timeout_sec) do
          Open3.capture3(@command, "exec", "--json", prompt)
        end
      end

      def prompt(bot_message)
        <<~PROMPT
          #{@role_prompt}

          Bot message:
          #{bot_message}

          Reply as the Telegram user. Respond with a JSON object only:
          {"reply": "..."}
        PROMPT
      end

      def parse_reply(stdout)
        agent_text = stdout.to_s.lines.filter_map do |line|
          parse_json_line(line)&.dig("item", "text")
        end.last
        doc = JSON.parse(extract_json_object(agent_text || stdout))
        doc.fetch("reply").to_s
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
        raise JSON::ParserError, "no JSON object in persona output" unless match

        match[0]
      end
    end
  end
end
