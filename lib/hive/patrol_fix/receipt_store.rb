require "json"
require "time"
require "hive/patrol_fix"
require "hive/canonical_json"

module Hive
  module PatrolFix
    class ReceiptStore
      FILENAME = "patrol-fix-receipts.jsonl".freeze
      LOCK_FILENAME = ".patrol-fix-receipts.lock".freeze
      SCHEMA = "hive-patrol-fix-receipt".freeze
      SCHEMA_VERSION = 1
      MAX_RECEIPT_BYTES = 64 * 1024
      MAX_JOURNAL_BYTES = 2 * 1024 * 1024
      MAX_RECEIPTS = 256
      MAX_TEXT_BYTES = 16 * 1024
      MAX_LIST = 128
      DIGEST = /\A[0-9a-f]{64}\z/
      REVISION = /\A[0-9a-f]{40}\z/
      SLUG = TaskManifest::SLUG
      KINDS = %w[decision fix validation publication publication_block reopen].freeze
      STAGES = %w[inbox fix validate review publish].freeze
      DECISION_ROUTES = {
        "inbox" => %w[fix escalate reject blocked],
        "review" => %w[publish rework escalate reject blocked]
      }.freeze

      class InvalidReceipt < Hive::Error; end

      attr_reader :task_folder, :path

      def initialize(task_folder:)
        @task_folder = File.expand_path(task_folder)
        @path = File.join(@task_folder, FILENAME)
        @lock_path = File.join(@task_folder, LOCK_FILENAME)
      end

      def read_all
        return [].freeze unless File.exist?(path) || File.symlink?(path)

        bytes = read_bytes
        invalid!("receipt journal must end at a complete record") unless bytes.empty? || bytes.end_with?("\n")
        lines = bytes.lines
        invalid!("receipt journal exceeds #{MAX_RECEIPTS} records") if lines.length > MAX_RECEIPTS
        receipts = lines.each_with_index.map do |line, index|
          invalid!("receipt #{index + 1} exceeds the size limit") if line.bytesize > MAX_RECEIPT_BYTES
          validate!(JSON.parse(line), label: "receipt #{index + 1}")
        rescue JSON::ParserError => e
          invalid!("receipt #{index + 1} is malformed JSON: #{e.message}")
        end
        ids = receipts.map { |receipt| receipt.fetch("receipt_id") }
        invalid!("receipt ids must be unique") unless ids.uniq.length == ids.length
        terminal_keys = receipts.map { |receipt| terminal_key(receipt) }
        unless terminal_keys.uniq.length == terminal_keys.length
          invalid!("terminal receipt tuples must be unique")
        end
        PatrolFix.deep_freeze(receipts)
      end

      # Semantic progress owned by the append-only Patrol Fix state machine.
      # The task manifest intentionally stays immutable while stage controllers
      # append receipts, so attempt generations must include this projection to
      # distinguish the next controller action from the one that just finished.
      def progress_token
        Hive::CanonicalJSON.digest(
          "owner" => "patrol_fix",
          "receipts" => read_all
        )
      rescue InvalidReceipt, JSON::GeneratorError, ArgumentError => e
        Hive::CanonicalJSON.digest(
          "owner" => "patrol_fix", "state" => "unreadable", "error" => e.class.name
        )
      end

      def append!(document)
        receipt = validate!(PatrolFix.deep_copy(document))
        line = PatrolFix.canonical_json(receipt)
        invalid!("receipt exceeds the size limit") if line.bytesize > MAX_RECEIPT_BYTES
        Dir.mkdir(task_folder) unless File.directory?(task_folder)

        lock_flags = File::RDWR | File::CREAT | File::NONBLOCK
        lock_flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        File.open(@lock_path, lock_flags, 0o600) do |lock|
          invalid!("receipt lock must be a regular file") unless lock.stat.file? && lock.stat.nlink == 1
          lock.flock(File::LOCK_EX)
          existing = read_all
          match = existing.find { |candidate| candidate["receipt_id"] == receipt["receipt_id"] }
          if match
            invalid!("receipt id already exists with conflicting bytes") unless match == receipt
            return match
          end
          terminal = existing.find { |candidate| terminal_key(candidate) == terminal_key(receipt) }
          invalid!("terminal receipt already exists with conflicting bytes") if terminal
          invalid!("receipt journal exceeds #{MAX_RECEIPTS} records") if existing.length >= MAX_RECEIPTS
          existing_bytes = File.exist?(path) ? File.size(path) : 0
          invalid!("receipt journal exceeds the size limit") if existing_bytes + line.bytesize > MAX_JOURNAL_BYTES
          reject_symlink!(path, "receipt journal")

          flags = File::WRONLY | File::CREAT | File::APPEND | File::NONBLOCK
          flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
          File.open(path, flags, 0o600) do |journal|
            invalid!("receipt journal must be a regular file") unless journal.stat.file?
            journal.write(line)
            journal.flush
            journal.fsync
          end
        end
        receipt
      rescue Errno::ELOOP
        invalid!("receipt journal must not be a symlink")
      rescue SystemCallError, IOError => e
        invalid!("receipt journal is unwritable: #{e.message}")
      rescue JSON::GeneratorError, ArgumentError => e
        invalid!(e.message)
      end

      private

      def validate!(receipt, label: "receipt")
        hash!(receipt, label)
        exact_keys!(receipt, %w[
          schema schema_version receipt_id kind stage task evidence_revision recorded_at payload
        ], label)
        invalid!("unknown receipt schema") unless receipt["schema"] == SCHEMA
        invalid!("unknown receipt schema version") unless receipt["schema_version"] == SCHEMA_VERSION
        string!(receipt.fetch("receipt_id"), "#{label}.receipt_id", max: 128)
        kind = receipt.fetch("kind")
        stage = receipt.fetch("stage")
        invalid!("#{label}.kind is unknown") unless KINDS.include?(kind)
        invalid!("#{label}.stage is unknown") unless STAGES.include?(stage)
        validate_task!(receipt.fetch("task"), label)
        validate_revision!(receipt.fetch("evidence_revision"), label)
        invalid!("#{label} task and evidence generations must match") unless
          receipt.dig("task", "generation") == receipt.dig("evidence_revision", "generation")
        timestamp!(receipt.fetch("recorded_at"), "#{label}.recorded_at")
        validate_payload!(kind, stage, receipt.fetch("payload"), label)
        PatrolFix.deep_freeze(receipt)
      end

      def validate_task!(task, label)
        hash!(task, "#{label}.task")
        exact_keys!(task, %w[slug generation], "#{label}.task")
        string!(task.fetch("slug"), "#{label}.task.slug", max: 64, pattern: SLUG)
        positive_integer!(task.fetch("generation"), "#{label}.task.generation")
      end

      def validate_revision!(revision, label)
        hash!(revision, "#{label}.evidence_revision")
        exact_keys!(revision, %w[generation digest], "#{label}.evidence_revision")
        positive_integer!(revision.fetch("generation"), "#{label}.evidence_revision.generation")
        string!(revision.fetch("digest"), "#{label}.evidence_revision.digest", max: 64, pattern: DIGEST)
      end

      def validate_payload!(kind, stage, payload, label)
        hash!(payload, "#{label}.payload")
        case kind
        when "decision" then validate_decision!(stage, payload, label)
        when "fix" then validate_fix!(stage, payload, label)
        when "validation" then validate_validation!(stage, payload, label)
        when "publication" then validate_publication!(stage, payload, label)
        when "publication_block" then validate_publication_block!(stage, payload, label)
        when "reopen" then validate_reopen!(stage, payload, label)
        end
      end

      def validate_decision!(stage, payload, label)
        invalid!("decision receipts are only valid for inbox or review") unless DECISION_ROUTES.key?(stage)
        fields = %w[route rationale evidence blocker_owner head_revision]
        fields += %w[diff_digest fix_receipt_id validation_receipt_id] if stage == "review"
        exact_keys!(payload, fields, "#{label}.payload")
        invalid!("#{label}.payload.route is invalid for #{stage}") unless
          DECISION_ROUTES.fetch(stage).include?(payload["route"])
        string!(payload.fetch("rationale"), "#{label}.payload.rationale", max: MAX_TEXT_BYTES)
        string_array!(payload.fetch("evidence"), "#{label}.payload.evidence", min: 1,
                      max: MAX_LIST, item_max: MAX_TEXT_BYTES)
        string!(payload.fetch("blocker_owner"), "#{label}.payload.blocker_owner", max: 128)
        string!(payload.fetch("head_revision"), "#{label}.payload.head_revision", max: 40, pattern: REVISION)
        return unless stage == "review"

        string!(payload.fetch("diff_digest"), "#{label}.payload.diff_digest", max: 64, pattern: DIGEST)
        %w[fix_receipt_id validation_receipt_id].each do |key|
          string!(payload.fetch(key), "#{label}.payload.#{key}", max: 128)
        end
      end

      def terminal_key(receipt)
        kind = if %w[publication publication_block].include?(receipt.fetch("kind"))
          "publication_result"
        else
          receipt.fetch("kind")
        end
        [
          receipt.dig("task", "slug"), receipt.fetch("stage"),
          receipt.dig("task", "generation"), kind
        ]
      end

      def validate_fix!(stage, payload, label)
        invalid!("fix receipts require the fix stage") unless stage == "fix"
        exact_keys!(payload, %w[worktree_generation worktree branch base_revision head_revision diff_digest validation_commands],
                    "#{label}.payload")
        positive_integer!(payload.fetch("worktree_generation"), "#{label}.payload.worktree_generation")
        %w[worktree branch].each { |key| string!(payload.fetch(key), "#{label}.payload.#{key}", max: 4_096) }
        %w[base_revision head_revision].each do |key|
          string!(payload.fetch(key), "#{label}.payload.#{key}", max: 40, pattern: REVISION)
        end
        string!(payload.fetch("diff_digest"), "#{label}.payload.diff_digest", max: 64, pattern: DIGEST)
        commands = array!(payload.fetch("validation_commands"), "#{label}.payload.validation_commands", min: 0, max: 16)
        commands.each_with_index do |command, index|
          item = "#{label}.payload.validation_commands[#{index}]"
          hash!(command, item)
          exact_keys!(command, %w[identity command provenance], item)
          string!(command.fetch("identity"), "#{item}.identity", max: 128)
          string!(command.fetch("command"), "#{item}.command", max: 4_096)
          invalid!("#{item}.provenance is invalid") unless command["provenance"] == "agent"
        end
      end

      def validate_validation!(stage, payload, label)
        invalid!("validation receipts require the validate stage") unless stage == "validate"
        exact_keys!(payload, %w[verdict worktree_head commands], "#{label}.payload")
        invalid!("#{label}.payload.verdict is invalid") unless %w[passed failed blocked].include?(payload["verdict"])
        string!(payload.fetch("worktree_head"), "#{label}.payload.worktree_head", max: 40, pattern: REVISION)
        commands = array!(payload.fetch("commands"), "#{label}.payload.commands", min: 0, max: 64)
        commands.each_with_index do |command, index|
          item = "#{label}.payload.commands[#{index}]"
          hash!(command, item)
          exact_keys!(command, %w[identity provenance command_digest started_at finished_at duration_ms exit_status timed_out output_truncated stdout stderr result_digest], item)
          string!(command.fetch("identity"), "#{item}.identity", max: 4_096)
          invalid!("#{item}.provenance is invalid") unless %w[controller agent].include?(command["provenance"])
          string!(command.fetch("command_digest"), "#{item}.command_digest", max: 64, pattern: DIGEST)
          timestamp!(command.fetch("started_at"), "#{item}.started_at")
          timestamp!(command.fetch("finished_at"), "#{item}.finished_at")
          invalid!("#{item}.duration_ms must be non-negative") unless command["duration_ms"].is_a?(Integer) && command["duration_ms"] >= 0
          invalid!("#{item}.exit_status must be a non-negative integer") unless
            command["exit_status"].is_a?(Integer) && command["exit_status"] >= 0
          string!(command.fetch("result_digest"), "#{item}.result_digest", max: 64, pattern: DIGEST)
          %w[timed_out output_truncated].each do |key|
            invalid!("#{item}.#{key} must be boolean") unless command[key] == true || command[key] == false
          end
          %w[stdout stderr].each { |key| bounded_text!(command.fetch(key), "#{item}.#{key}", max: 4_000) }
        end
      end

      def validate_publication!(stage, payload, label)
        invalid!("publication receipts require the publish stage") unless stage == "publish"
        require "hive/patrol_fix/publication_receipt"
        Hive::PatrolFix::PublicationReceipt.validate_payload!(payload)
      rescue Hive::PatrolFix::PublicationReceipt::InvalidPublication => e
        invalid!("#{label}.payload #{e.message}")
      end

      def validate_publication_block!(stage, payload, label)
        invalid!("publication block receipts require the publish stage") unless stage == "publish"
        require "hive/patrol_fix/publication_block_receipt"
        Hive::PatrolFix::PublicationBlockReceipt.validate_payload!(payload)
      rescue Hive::PatrolFix::PublicationBlockReceipt::InvalidBlock => e
        invalid!("#{label}.payload #{e.message}")
      end

      def validate_reopen!(stage, payload, label)
        invalid!("reopen receipts are only valid for inbox, review, or publish") unless
          (DECISION_ROUTES.keys + [ "publish" ]).include?(stage)
        exact_keys!(payload, %w[outcome_receipt_id operator carried_receipts], "#{label}.payload")
        string!(payload.fetch("outcome_receipt_id"), "#{label}.payload.outcome_receipt_id", max: 128)
        string!(payload.fetch("operator"), "#{label}.payload.operator", max: 256)
        carried = array!(payload.fetch("carried_receipts"), "#{label}.payload.carried_receipts", min: 0, max: 2)
        carried.each_with_index do |receipt_id, index|
          string!(receipt_id, "#{label}.payload.carried_receipts[#{index}]", max: 128)
        end
        invalid!("#{label}.payload.carried_receipts must be unique") unless carried.uniq == carried
      end

      def read_bytes
        reject_symlink!(path, "receipt journal")
        stat = File.lstat(path)
        invalid!("receipt journal must be a regular file") unless stat.file?
        invalid!("receipt journal exceeds the size limit") if stat.size > MAX_JOURNAL_BYTES
        flags = File::RDONLY | File::NONBLOCK
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        File.open(path, flags) do |file|
          invalid!("receipt journal must be a regular file") unless file.stat.file? && file.stat.nlink == 1
          bytes = file.read(MAX_JOURNAL_BYTES + 1).to_s
          invalid!("receipt journal exceeds the size limit") if bytes.bytesize > MAX_JOURNAL_BYTES
          bytes
        end
      rescue Errno::ELOOP
        invalid!("receipt journal must not be a symlink")
      rescue SystemCallError, IOError => e
        invalid!("receipt journal is unreadable: #{e.message}")
      end

      def reject_symlink!(candidate, label)
        invalid!("#{label} must not be a symlink") if File.symlink?(candidate)
      end

      def exact_keys!(value, keys, label)
        invalid!("#{label} fields must be exactly #{keys.join(', ')}") unless value.keys.sort == keys.sort
      end

      def hash!(value, label)
        invalid!("#{label} must be an object") unless value.is_a?(Hash)
      end

      def array!(value, label, min:, max:)
        invalid!("#{label} must be an array") unless value.is_a?(Array)
        invalid!("#{label} must contain at least #{min} entries") if value.length < min
        invalid!("#{label} exceeds #{max} entries") if value.length > max
        value
      end

      def string_array!(value, label, min:, max:, item_max:)
        array!(value, label, min: min, max: max).each_with_index do |entry, index|
          string!(entry, "#{label}[#{index}]", max: item_max)
        end
      end

      def string!(value, label, max:, pattern: nil)
        invalid!("#{label} must be a non-empty string") unless value.is_a?(String) && !value.empty?
        invalid!("#{label} exceeds #{max} bytes") if value.bytesize > max
        invalid!("#{label} contains invalid control characters") if value.match?(/[\u0000-\u001f\u007f]/)
        invalid!("#{label} has an invalid format") if pattern && !value.match?(pattern)
      end

      def bounded_text!(value, label, max:)
        invalid!("#{label} must be a string") unless value.is_a?(String)
        invalid!("#{label} exceeds #{max} bytes") if value.bytesize > max
        invalid!("#{label} contains invalid control characters") if value.match?(/[\u0000\u007f]/)
      end

      def positive_integer!(value, label)
        invalid!("#{label} must be a positive integer") unless value.is_a?(Integer) && value.positive?
      end

      def timestamp!(value, label)
        string!(value, label, max: 64)
        parsed = Time.iso8601(value)
        invalid!("#{label} must be UTC") unless parsed.utc? && value.end_with?("Z")
      rescue ArgumentError
        invalid!("#{label} must be an ISO 8601 UTC timestamp")
      end

      def invalid!(message)
        raise InvalidReceipt, message.to_s[0, 512]
      end
    end
  end
end
