module HiveLiveAgentProof
  module OpenClawCreatorGatewayRuntime
    class CandidateExecutor
      RETAINED_STDOUT_LIMIT = 64 * 1024
      PARSED_RESULT_ORDINALS = [ 4, 6, 8 ].freeze

      Result = Struct.new(
        :status, :success, :exit_code, :reason, :result_record,
        keyword_init: true
      )

      def initialize(candidate:, credential_names:, safe_slug:)
        @candidate = candidate
        @credential_names = credential_names
        @safe_slug = safe_slug
      end

      def call(argv:, ordinal:, attempt_id:)
        retained = +""
        status = stream_candidate(argv, retained)
        success = status.success?
        exit_code = status.exitstatus || 1
        reason = success ? "completed" : "candidate_failed"
        result_record = nil
        if success && PARSED_RESULT_ORDINALS.include?(ordinal)
          result_record = parse_result(
            retained, ordinal: ordinal, attempt_id: attempt_id
          )
          unless result_record
            success = false
            exit_code = 67
            reason = "candidate_output_invalid"
          end
        end
        Result.new(
          status: status,
          success: success,
          exit_code: exit_code,
          reason: reason,
          result_record: result_record
        )
      end

      private

      def stream_candidate(argv, retained)
        status = nil
        Open3.popen3(
          candidate_environment, @candidate, *argv, unsetenv_others: true
        ) do |input, output, error, waiter|
          input.close
          stdout_reader = Thread.new { copy_stdout(output, retained) }
          stderr_reader = Thread.new { copy_stream(error, STDERR) }
          status = waiter.value
          stdout_reader.join
          stderr_reader.join
        end
        status
      end

      def candidate_environment
        ENV.to_h.reject { |name, _value| @credential_names.include?(name) }.tap do |env|
          env.delete("HIVE_PROVEN_HIVE_BIN")
          env.delete("HIVE_OPENCLAW_BIN")
          env.delete("HIVE_CANDIDATE_INSTALL_RECEIPT")
          env.delete("HIVE_OPENCLAW_INSTALL_RECEIPT")
          env["HIVE_BIN"] = @candidate
        end
      end

      def copy_stdout(source, retained)
        loop do
          chunk = source.readpartial(16 * 1024)
          STDOUT.write(chunk)
          if retained.bytesize < RETAINED_STDOUT_LIMIT
            retained << chunk.byteslice(0, RETAINED_STDOUT_LIMIT - retained.bytesize)
          end
        end
      rescue EOFError
        nil
      end

      def copy_stream(source, destination)
        loop { destination.write(source.readpartial(16 * 1024)) }
      rescue EOFError
        nil
      end

      def parse_result(retained, ordinal:, attempt_id:)
        payload = retained.lines.reverse_each.filter_map do |line|
          JSON.parse(line)
        rescue JSON::ParserError
          nil
        end.find { |row| row.is_a?(Hash) }
        case ordinal
        when 4
          validation_record(payload, ordinal: ordinal, attempt_id: attempt_id)
        when 6, 8
          task_creation_record(payload, ordinal: ordinal, attempt_id: attempt_id)
        end
      end

      def validation_record(payload, ordinal:, attempt_id:)
        unless payload && payload["schema"] == "hive-workflow-validate" &&
               payload["valid"] == true
          warn "workflow-creator proof could not parse validation output"
          return
        end

        {
          "attempt_id" => attempt_id,
          "ordinal" => ordinal,
          "kind" => "validation",
          "valid" => true,
          "stages" => Array(payload["stages"]).map { |stage| stage["name"] },
          "automatic_edges" => Array(payload["automatic_edges"]).map {
            |edge| [ edge["from"], edge["to"] ]
          },
          "human_outcomes" => payload["human_outcomes"]
        }
      end

      def task_creation_record(payload, ordinal:, attempt_id:)
        unless payload && payload["schema"] == "hive-new" &&
               [ true, false ].include?(payload["created"]) &&
               @safe_slug.match?(payload["slug"].to_s)
          warn "workflow-creator proof could not parse task creation output"
          return
        end

        {
          "attempt_id" => attempt_id,
          "ordinal" => ordinal,
          "kind" => "task_creation",
          "slug" => payload.fetch("slug"),
          "created" => payload.fetch("created")
        }
      end
    end
  end
end
