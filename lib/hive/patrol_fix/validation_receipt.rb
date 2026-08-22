require "digest"
require "time"
require "hive/secret_patterns"

module Hive
  module PatrolFix
    module ValidationReceipt
      module_function
      OUTPUT_BYTES = 4_000

      def build(worktree_head:, results:)
        rows = Array(results).map do |result|
          full_stdout = redacted(result.stdout)
          full_stderr = redacted(result.stderr)
          stdout, stdout_truncated = bounded_tail(full_stdout)
          stderr, stderr_truncated = bounded_tail(full_stderr)
          values = {
            "identity" => result.name.to_s,
            "provenance" => (result.respond_to?(:provenance) ? result.provenance : nil).to_s.empty? ? "controller" : result.provenance.to_s,
            "command_digest" => Digest::SHA256.hexdigest(result.command.to_s),
            "started_at" => result.started_at.utc.iso8601(6),
            "finished_at" => result.finished_at.utc.iso8601(6),
            "duration_ms" => result.duration_ms.to_i,
            "exit_status" => result.exit_code.to_i,
            "timed_out" => result.timed_out == true,
            "output_truncated" => result.output_truncated == true || stdout_truncated || stderr_truncated,
            "stdout" => stdout, "stderr" => stderr
          }
          digest_values = values.merge(
            "stdout" => Digest::SHA256.hexdigest(full_stdout),
            "stderr" => Digest::SHA256.hexdigest(full_stderr)
          )
          values["result_digest"] = Digest::SHA256.hexdigest(
            Hive::PatrolFix.canonical_json(digest_values)
          )
          values
        end
        verdict = if rows.empty? then "blocked" elsif rows.all? { |row| row["exit_status"].zero? && !row["timed_out"] } then "passed" else "failed" end
        { "verdict" => verdict, "worktree_head" => worktree_head, "commands" => rows }
      end

      def redacted(value)
        text = value.to_s.dup.force_encoding(Encoding::UTF_8).scrub("?")
        Hive::SecretPatterns.redact(text)
      end
      private_class_method :redacted

      def bounded_tail(text)
        return [ text, false ] if text.bytesize <= OUTPUT_BYTES

        tail = text.byteslice(-OUTPUT_BYTES, OUTPUT_BYTES).to_s
          .force_encoding(Encoding::UTF_8).scrub("?")
        tail = tail.each_char.drop(1).join while tail.bytesize > OUTPUT_BYTES
        [ tail, true ]
      end
      private_class_method :bounded_tail
    end
  end
end
