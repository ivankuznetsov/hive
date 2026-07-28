module HiveLiveAgentProof
  module OpenClawCreatorGatewayRuntime
    class ResultLedger
      MAX_BYTES = 256 * 1024
      MAX_ROWS = 3
      MAX_LINE_BYTES = 128 * 1024
      RESULT_ORDINALS = [ 4, 6, 8 ].freeze
      ATTEMPT_ID = /\A[0-9a-f]{64}\z/
      VALIDATION_KEYS = %w[
        attempt_id automatic_edges human_outcomes kind ordinal stages valid
      ].freeze
      TASK_CREATION_KEYS = %w[
        attempt_id created kind ordinal slug
      ].freeze
      HUMAN_OUTCOME_KEYS = %w[artifact complete name stage to].freeze

      def initialize(path:, safe_slug:)
        @path = File.expand_path(path)
        @safe_slug = safe_slug
      end

      def read(attempt_pairs:)
        expected_ordinals = RESULT_ORDINALS.select {
          |ordinal| ordinal <= attempt_pairs.length
        }
        rows = read_rows
        raise InvalidLedger, "result ledger row count is invalid" unless
          rows.length == expected_ordinals.length

        rows.each_with_index do |row, index|
          ordinal = expected_ordinals.fetch(index)
          pair = attempt_pairs.fetch(ordinal - 1)
          validate_row!(row, ordinal: ordinal, pair: pair)
        end
        rows.freeze
      end

      private

      def read_rows
        content = BoundedRegularReader.new(
          path: @path,
          max_bytes: MAX_BYTES,
          label: "result ledger"
        ).read
        return [] if content.nil?

        raise InvalidLedger, "result ledger has a truncated row" unless
          content.empty? || content.end_with?("\n")

        lines = content.lines(chomp: true)
        raise InvalidLedger, "result ledger exceeds row budget" if lines.length > MAX_ROWS
        lines.map do |line|
          raise InvalidLedger, "result ledger contains an empty row" if line.empty?
          raise InvalidLedger, "result ledger row exceeds byte budget" if
            line.bytesize > MAX_LINE_BYTES

          JSON.parse(line)
        rescue JSON::ParserError => e
          raise InvalidLedger, "result ledger JSON is malformed: #{e.message}"
        end
      rescue InvalidLedger
        raise
      rescue SystemCallError, IOError => e
        raise InvalidLedger, "cannot read result ledger: #{e.message}"
      end

      def validate_row!(row, ordinal:, pair:)
        raise InvalidLedger, "result ledger row is not an object" unless row.is_a?(Hash)
        raise InvalidLedger, "result ledger ordinal is invalid" unless row["ordinal"] == ordinal

        attempted = pair.fetch(:attempted)
        terminal = pair.fetch(:terminal)
        raise InvalidLedger, "result ledger attempt binding is invalid" unless
          terminal.fetch("decision") == "succeeded" &&
          row["attempt_id"] == attempted.fetch("attempt_id") &&
          ATTEMPT_ID.match?(row["attempt_id"].to_s)

        ordinal == 4 ? validate_validation!(row) : validate_task_creation!(row)
      end

      def validate_validation!(row)
        raise InvalidLedger, "result ledger validation fields are invalid" unless
          row.keys.sort == VALIDATION_KEYS &&
          row["kind"] == "validation" &&
          row["valid"] == true &&
          string_array?(row["stages"]) &&
          edge_array?(row["automatic_edges"]) &&
          human_outcomes?(row["human_outcomes"])
      end

      def validate_task_creation!(row)
        raise InvalidLedger, "result ledger task fields are invalid" unless
          row.keys.sort == TASK_CREATION_KEYS &&
          row["kind"] == "task_creation" &&
          [ true, false ].include?(row["created"]) &&
          row["slug"].is_a?(String) &&
          @safe_slug.match?(row["slug"])
      end

      def string_array?(value)
        value.is_a?(Array) && value.length <= 32 &&
          value.all? { |item| bounded_string?(item) }
      end

      def edge_array?(value)
        value.is_a?(Array) && value.length <= 64 &&
          value.all? {
            |edge| edge.is_a?(Array) && edge.length == 2 &&
              edge.all? { |item| bounded_string?(item) }
          }
      end

      def human_outcomes?(value)
        value.is_a?(Array) && value.length <= 64 &&
          value.all? do |outcome|
            outcome.is_a?(Hash) &&
              outcome.keys.sort == HUMAN_OUTCOME_KEYS &&
              bounded_string?(outcome["stage"]) &&
              bounded_string?(outcome["name"]) &&
              [ true, false ].include?(outcome["complete"]) &&
              optional_string?(outcome["artifact"]) &&
              optional_string?(outcome["to"])
          end
      end

      def bounded_string?(value)
        value.is_a?(String) && !value.empty? && value.bytesize <= 256
      end

      def optional_string?(value)
        value.nil? || bounded_string?(value)
      end
    end
  end
end
