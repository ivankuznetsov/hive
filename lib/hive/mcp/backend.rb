require "json"
require "stringio"

module Hive
  module Mcp
    # In-process calls into the existing Hive command objects. The connector
    # never builds a shell command from model text.
    class Backend
      def status(_arguments)
        capture_stdout do
          require "hive/commands/status"
          Hive::Commands::Status.new(json: true, operational: true).call
        end
      end

      def task(arguments)
        capture_stdout do
          require "hive/commands/task"
          Hive::Commands::Task.new(
            arguments.fetch("target"),
            project: arguments["project"],
            json: arguments["log"] != true,
            log: arguments["log"] == true
          ).call
        end
      end

      def doctor(_arguments)
        output = StringIO.new
        require "hive/config"
        require "hive/commands/doctor"
        code = Hive::Commands::Doctor.new(
          config: Hive::Config.load(Dir.pwd),
          project_root: Dir.pwd,
          json: true,
          output: output
        ).call
        text = output.string.strip
        return document_result(text) if text.start_with?("{", "[")

        result("hive doctor exited #{code} without a JSON document", code != 0)
      rescue StandardError => error
        text = output.string.to_s.strip
        return document_result(text, error) if text.start_with?("{", "[")

        result("#{error.class}: #{error.message}", true)
      end

      def answer_inventory(arguments)
        answer(arguments, binding: nil, answer: nil)
      end

      def answer_write(arguments)
        answer(
          arguments,
          binding: arguments.fetch("binding"),
          answer: arguments.fetch("answer")
        )
      end

      def act(arguments)
        capture_stdout do
          require "hive/commands/act"
          Hive::Commands::Act.new(
            arguments.fetch("action_id"),
            arguments.fetch("target"),
            observation: arguments.fetch("observation"),
            json: true
          ).call
        end
      end

      private

      def answer(arguments, binding:, answer:)
        output = StringIO.new
        require "hive/commands/answer"
        kwargs = {
          project: arguments["project"],
          json: true,
          output: output
        }
        if binding
          kwargs[:binding] = binding
          kwargs[:input] = StringIO.new(answer.to_s)
        end
        Hive::Commands::Answer.new(arguments.fetch("target"), **kwargs).call
        document_result(output.string)
      rescue StandardError => error
        document_result(output.string, error)
      end

      def capture_stdout
        stdout = StringIO.new
        previous = $stdout
        $stdout = stdout
        begin
          yield
          document_result(stdout.string)
        rescue SystemExit => error
          document_result(stdout.string, error.success? ? nil : error)
        rescue StandardError => error
          document_result(stdout.string, error)
        ensure
          $stdout = previous
        end
      end

      def document_result(stdout, error = nil)
        text = stdout.to_s.strip
        if text.start_with?("{", "[")
          begin
            parsed = JSON.parse(text)
            failed = parsed.is_a?(Hash) && parsed["ok"] == false
            return result(text, failed)
          rescue JSON::ParserError
            nil
          end
        end

        return result("#{error.class}: #{error.message}", true) if error

        result(text, false)
      end

      def result(text, is_error)
        { text: text, is_error: is_error }
      end
    end
  end
end
