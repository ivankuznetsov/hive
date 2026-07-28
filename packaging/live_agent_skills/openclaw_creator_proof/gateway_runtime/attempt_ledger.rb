module HiveLiveAgentProof
  module OpenClawCreatorGatewayRuntime
    class LedgerError < StandardError; end
    class InvalidLedger < LedgerError; end
    class LedgerWriteFailed < LedgerError; end

    class DurableJsonLineAppender
      def initialize(path, open_file: File.method(:open))
        @path = File.expand_path(path)
        @open_file = open_file
      end

      def append(payload)
        directory = File.dirname(@path)
        FileUtils.mkdir_p(directory, mode: 0o700)
        reject_existing_non_regular!
        encoded = "#{JSON.generate(payload)}\n"
        flags = File::WRONLY | File::CREAT | File::APPEND
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        @open_file.call(@path, flags, 0o600) do |file|
          raise LedgerWriteFailed, "audit target is not a regular file" unless file.stat.file?

          written = file.write(encoded)
          raise LedgerWriteFailed, "audit write was incomplete" unless written == encoded.bytesize

          file.flush
          file.fsync
        end
      rescue LedgerWriteFailed
        raise
      rescue SystemCallError, IOError => e
        raise LedgerWriteFailed, "audit write/fsync failed: #{e.message}"
      end

      private

      def reject_existing_non_regular!
        return unless File.exist?(@path) || File.symlink?(@path)

        stat = File.lstat(@path)
        raise LedgerWriteFailed, "audit target is not a regular file" unless
          stat.file? && !stat.symlink?
      rescue SystemCallError => e
        raise LedgerWriteFailed, "cannot inspect audit target: #{e.message}"
      end
    end

    class AttemptLedger
      SCHEMA = "hive-openclaw-command-attempt".freeze
      SCHEMA_VERSION = 2
      MAX_BYTES = 512 * 1024
      MAX_ROWS = 64
      MAX_LINE_BYTES = 32 * 1024
      ATTEMPT_ID = /\A[0-9a-f]{64}\z/
      ATTEMPTED_KEYS = %w[
        argv attempt_id candidate_realpath candidate_sha256 ordinal phase schema
        schema_version
      ].freeze
      TERMINAL_KEYS = %w[
        argv attempt_id candidate_realpath candidate_sha256 decision dynamic_slug
        exit_status expected_argv ordinal phase reason schema schema_version signal
        success
      ].freeze
      DECISIONS = %w[succeeded denied failed].freeze

      State = Struct.new(:pairs, :pending, keyword_init: true) do
        def completed_count
          pairs.length
        end

        def poisoned_terminal
          pairs.filter_map { |pair| pair.fetch(:terminal) }
               .find { |row| row.fetch("decision") != "succeeded" }
        end
      end

      def initialize(path:, candidate_realpath:, candidate_sha256:, appender: nil)
        @path = File.expand_path(path)
        @candidate_realpath = candidate_realpath.to_s
        @candidate_sha256 = candidate_sha256.to_s
        @appender = appender || DurableJsonLineAppender.new(@path)
      end

      def read
        rows = read_rows
        pairs = []
        pending = nil
        rows.each do |row|
          if pending
            validate_terminal!(row, pending)
            pairs << { attempted: pending, terminal: row }
            pending = nil
          else
            validate_attempted!(row, pairs)
            pending = row
          end
        end
        State.new(pairs: pairs.freeze, pending: pending)
      end

      def begin_attempt(state:, argv:)
        ordinal = state.completed_count + 1
        row = {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "phase" => "attempted",
          "attempt_id" => attempt_id(
            ordinal: ordinal,
            argv: argv,
            previous_id: state.pairs.last&.dig(:attempted, "attempt_id")
          ),
          "ordinal" => ordinal,
          "argv" => argv.map(&:to_s),
          "candidate_realpath" => @candidate_realpath,
          "candidate_sha256" => @candidate_sha256
        }
        @appender.append(row)
        row.freeze
      end

      def finish_attempt(attempt:, expected_argv:, dynamic_slug:, decision:, reason:,
                         exit_status: nil, signal: nil)
        row = {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "phase" => "terminal",
          "attempt_id" => attempt.fetch("attempt_id"),
          "ordinal" => attempt.fetch("ordinal"),
          "argv" => attempt.fetch("argv"),
          "expected_argv" => expected_argv,
          "dynamic_slug" => dynamic_slug,
          "candidate_realpath" => @candidate_realpath,
          "candidate_sha256" => @candidate_sha256,
          "decision" => decision,
          "reason" => reason,
          "exit_status" => exit_status,
          "signal" => signal,
          "success" => decision == "succeeded"
        }
        validate_terminal!(row, attempt)
        @appender.append(row)
        row.freeze
      end

      private

      def read_rows
        return [] unless File.exist?(@path) || File.symlink?(@path)

        stat = File.lstat(@path)
        raise InvalidLedger, "audit ledger is not a regular file" unless
          stat.file? && !stat.symlink?
        raise InvalidLedger, "audit ledger exceeds byte budget" if stat.size > MAX_BYTES

        content = File.binread(@path)
        raise InvalidLedger, "audit ledger has a truncated row" unless
          content.empty? || content.end_with?("\n")

        lines = content.lines(chomp: true)
        raise InvalidLedger, "audit ledger exceeds row budget" if lines.length > MAX_ROWS
        lines.map do |line|
          raise InvalidLedger, "audit ledger contains an empty row" if line.empty?
          raise InvalidLedger, "audit ledger row exceeds byte budget" if
            line.bytesize > MAX_LINE_BYTES

          JSON.parse(line)
        rescue JSON::ParserError => e
          raise InvalidLedger, "audit ledger JSON is malformed: #{e.message}"
        end
      rescue InvalidLedger
        raise
      rescue SystemCallError => e
        raise InvalidLedger, "cannot read audit ledger: #{e.message}"
      end

      def validate_attempted!(row, pairs)
        ordinal = pairs.length + 1
        valid_common!(row, keys: ATTEMPTED_KEYS, phase: "attempted", ordinal: ordinal)
        previous_id = pairs.last&.dig(:attempted, "attempt_id")
        expected_id = attempt_id(
          ordinal: ordinal, argv: row.fetch("argv"), previous_id: previous_id
        )
        raise InvalidLedger, "audit ledger attempt id is invalid" unless
          row["attempt_id"] == expected_id
      end

      def validate_terminal!(row, attempted)
        valid_common!(
          row, keys: TERMINAL_KEYS, phase: "terminal",
          ordinal: attempted.fetch("ordinal")
        )
        raise InvalidLedger, "audit ledger terminal identity is mismatched" unless
          row["attempt_id"] == attempted["attempt_id"] &&
          row["argv"] == attempted["argv"]
        raise InvalidLedger, "audit ledger terminal decision is invalid" unless
          DECISIONS.include?(row["decision"])
        raise InvalidLedger, "audit ledger terminal reason is invalid" unless
          row["reason"].is_a?(String) && !row["reason"].empty? &&
          row["reason"].bytesize <= 128
        raise InvalidLedger, "audit ledger expected argv is invalid" unless
          row["expected_argv"].nil? || argv?(row["expected_argv"])
        raise InvalidLedger, "audit ledger dynamic slug is invalid" unless
          row["dynamic_slug"].nil? || row["dynamic_slug"].is_a?(String)
        raise InvalidLedger, "audit ledger exit status is invalid" unless
          row["exit_status"].nil? ||
          (row["exit_status"].is_a?(Integer) && row["exit_status"].between?(0, 255))
        raise InvalidLedger, "audit ledger signal is invalid" unless
          row["signal"].nil? ||
          (row["signal"].is_a?(Integer) && row["signal"].positive?)

        validate_decision_fields!(row)
      end

      def valid_common!(row, keys:, phase:, ordinal:)
        raise InvalidLedger, "audit ledger row is not an object" unless row.is_a?(Hash)
        raise InvalidLedger, "audit ledger row fields are invalid" unless
          row.keys.sort == keys
        raise InvalidLedger, "audit ledger schema is invalid" unless
          row["schema"] == SCHEMA && row["schema_version"] == SCHEMA_VERSION
        raise InvalidLedger, "audit ledger phase is invalid" unless row["phase"] == phase
        raise InvalidLedger, "audit ledger ordinal is invalid" unless row["ordinal"] == ordinal
        raise InvalidLedger, "audit ledger argv is invalid" unless argv?(row["argv"])
        raise InvalidLedger, "audit ledger attempt id is invalid" unless
          ATTEMPT_ID.match?(row["attempt_id"].to_s)
        raise InvalidLedger, "audit ledger candidate identity is invalid" unless
          row["candidate_realpath"] == @candidate_realpath &&
          row["candidate_sha256"] == @candidate_sha256
      end

      def validate_decision_fields!(row)
        case row.fetch("decision")
        when "succeeded"
          raise InvalidLedger, "audit ledger success fields are invalid" unless
            row["reason"] == "completed" && row["success"] == true &&
            row["exit_status"] == 0 && row["signal"].nil? &&
            row["expected_argv"] == row["argv"]
        when "denied"
          raise InvalidLedger, "audit ledger denial fields are invalid" unless
            row["success"] == false && row["exit_status"].nil? && row["signal"].nil?
        when "failed"
          raise InvalidLedger, "audit ledger failure fields are invalid" unless
            row["success"] == false
        end
      end

      def argv?(value)
        value.is_a?(Array) && value.length <= 64 &&
          value.all? { |argument| argument.is_a?(String) && argument.bytesize <= 4_096 }
      end

      def attempt_id(ordinal:, argv:, previous_id:)
        # This deterministic chain detects corruption, truncation, and broken pairing.
        # It is not authenticity evidence against a coherent same-UID rewrite.
        Digest::SHA256.hexdigest(
          JSON.generate(
            "schema" => SCHEMA,
            "schema_version" => SCHEMA_VERSION,
            "ordinal" => ordinal,
            "argv" => argv,
            "previous_attempt_id" => previous_id,
            "candidate_realpath" => @candidate_realpath,
            "candidate_sha256" => @candidate_sha256
          )
        )
      end
    end
  end
end
