require "hive/lock"
require "hive/markers"
require "hive/bot/brainstorm_parser"

module Hive
  module Bot
    module BrainstormAnswerWriter
      module_function

      # `answer_slot_missing` is a new variant: the question was located
      # in the file but no fillable A-section was found between it and
      # the next block boundary. Previously this case was conflated with
      # `question_not_found`, producing the misleading "Question N was
      # not found" reply when Q{n} was present but its A-slot was
      # malformed or missing. Supervisor renders a distinct message.
      RESULTS = %i[written already_answered lock_busy question_not_found answer_slot_missing].freeze

      # Reuse the parser's regex constants so both modules can never drift
      # apart. The previous in-file copies subtly diverged (the writer's
      # QUESTION_RE matched a prefix without trailing-text capture; the
      # parser's captured the full title), which made it harder to reason
      # about boundary detection across the two modules. Single source of
      # truth: `Hive::Bot::BrainstormParser`.
      QUESTION_RE = Hive::Bot::BrainstormParser::QUESTION_RE
      ANSWER_RE   = Hive::Bot::BrainstormParser::ANSWER_RE
      ROUND_RE    = Hive::Bot::BrainstormParser::ROUND_RE
      MARKER_RE   = Hive::Bot::BrainstormParser::MARKER_RE

      LOCK_RETRY_DEADLINE_SEC = 5
      LOCK_RETRY_SLEEP_SEC = 0.05

      def append!(brainstorm_path:, question_n:, answer_text:, logger: nil)
        task_folder = File.dirname(brainstorm_path)
        raise Hive::InvalidTaskPath, "task folder does not exist: #{task_folder}" unless Dir.exist?(task_folder)

        deadline = Time.now + LOCK_RETRY_DEADLINE_SEC
        result = nil
        last_holder = nil
        loop do
          # try_append returns ONE of three shapes:
          #   [<symbol>, nil]   — terminal result, break the loop.
          #   [nil, holder]     — lock contention; keep retrying with sleep.
          #   [:enoent, nil]    — brainstorm.md vanished mid-write; terminal.
          # The retry-invariant is: only [nil, holder] (lock-busy) keeps the
          # loop spinning. Without distinguishing :enoent from lock-busy, a
          # deleted brainstorm.md silently hammered try_append for the full
          # 5-second deadline and ended up reported to the operator as
          # "Try again - another run holds the lock" — wrong cause.
          result, holder = try_append(task_folder, brainstorm_path, question_n, answer_text)
          break if result || Time.now >= deadline

          last_holder = holder if holder
          sleep LOCK_RETRY_SLEEP_SEC
        end

        if result.nil?
          # Emit a structured event so operators can grep the bot log to see
          # what was holding the per-task lock when the writer gave up.
          # holder fields come from Hive::Lock's lock-file YAML — typically
          # {pid:, started_at:, host:, op:, slug:, stage:, bot: …}.
          logger&.event(:answer_lock_contention,
                        task_folder: task_folder,
                        question_n: question_n,
                        deadline_sec: LOCK_RETRY_DEADLINE_SEC,
                        holder: last_holder)
          result = :lock_busy
        elsif result == :enoent
          # Distinct from lock_busy: the brainstorm.md file is gone. Map to
          # question_not_found since there is genuinely no Q to write into.
          # Supervisor's existing :question_not_found message ("Question N
          # was not found.") is honest in this case — there is no file, so
          # there is no question.
          logger&.event(:answer_lock_contention,
                        task_folder: task_folder,
                        question_n: question_n,
                        deadline_sec: LOCK_RETRY_DEADLINE_SEC,
                        holder: { reason: "brainstorm.md missing" })
          result = :question_not_found
        end

        raise "BrainstormAnswerWriter returned unknown result #{result.inspect}" unless RESULTS.include?(result)

        result
      end

      # Returns [result_symbol, holder_metadata_or_nil].
      #
      # Result symbol is the terminal RESULTS value when the write was
      # attempted (atomic write happened or not). `:enoent` is a sentinel
      # internal to the writer (mapped to `:question_not_found` by
      # append!) for the "brainstorm.md vanished" case. holder_metadata is
      # only set when the call FAILED to acquire the lock, in which case
      # the result is nil (and the retry loop in append! re-spins).
      def try_append(task_folder, brainstorm_path, question_n, answer_text)
        result = Hive::Lock.with_task_lock(task_folder, "bot" => "brainstorm_answer") do
          content = File.exist?(brainstorm_path) ? File.read(brainstorm_path, encoding: "UTF-8") : ""
          parsed = Hive::Bot::BrainstormParser.parse_text(content)
          if !parsed.any? { |question| question.n == question_n }
            next :question_not_found
          end
          if !parsed.any? { |question| question.n == question_n && question.answer.nil? }
            next :already_answered
          end

          lines = content.lines
          slot = find_empty_answer_slot(lines, question_n, parsed)
          if slot
            new_lines = fill_answer_slot(lines, slot, answer_text, content)
          else
            # Q{n} is unanswered (the earlier guards verified Q{n} is
            # present and its answer is nil) but has NO `### A{n}.` header
            # at all — the brainstorm agent emitted the question without a
            # fillable answer block. Rather than dead-end with
            # `:answer_slot_missing` (which left the operator unable to
            # answer and, with the daemon's answers-pending gate, held the
            # task indefinitely — issue #269), CREATE the slot at the end
            # of the Q-block and write the answer into it.
            new_lines = insert_answer_slot(lines, question_n, parsed, answer_text, content)
            next :answer_slot_missing unless new_lines
          end

          Hive::Markers.write_atomic(brainstorm_path, new_lines.join)
          :written
        end
        [ result, nil ]
      rescue Hive::ConcurrentRunError => e
        [ nil, e.holder ]
      rescue Errno::ENOENT
        # brainstorm.md vanished mid-write (rare: external rm, archive
        # move, disk error). Sentinel symbol routes append!'s retry
        # loop to terminate immediately instead of polling for the
        # full 5-second deadline.
        [ :enoent, nil ]
      end
      private_class_method :try_append

      # Write `answer_text` into an existing empty `### A` slot.
      def fill_answer_slot(lines, slot, answer_text, content)
        newline = newline_for(content)
        if slot[:answer_line_index] >= 0 && !lines[slot[:answer_line_index]].to_s.end_with?(newline)
          lines[slot[:answer_line_index]] = "#{lines[slot[:answer_line_index]]}#{newline}"
        end

        answer_lines = answer_body(answer_text, newline).lines
        lines[0..slot[:answer_line_index]] + answer_lines + lines[slot[:body_end_index]..].to_a
      end
      private_class_method :fill_answer_slot

      # #269: create a fresh `### A{n}.` slot for a question that has none,
      # at the end of the Q-block (just before the next Q / Round / marker
      # boundary, or EOF), and write the answer into it. Uses the parser's
      # canonical `answer_header` so the format stays in lockstep. Returns
      # the new lines, or nil when the Q{n} line can't be located (the
      # earlier guard makes this unreachable in practice; nil routes
      # `try_append` back to the `:answer_slot_missing` fallback).
      def insert_answer_slot(lines, question_n, parsed, answer_text, content)
        q_idx = target_question_line_index(lines, parsed, question_n)
        return nil unless q_idx

        newline = newline_for(content)
        insert_idx = q_idx + 1
        insert_idx += 1 while insert_idx < lines.length && !block_boundary?(lines[insert_idx])
        # Ensure the preceding line is newline-terminated so the new
        # header doesn't get glued onto the question's last body line.
        if insert_idx.positive? && !lines[insert_idx - 1].to_s.end_with?(newline)
          lines[insert_idx - 1] = "#{lines[insert_idx - 1]}#{newline}"
        end

        slot_lines = [ "#{Hive::Bot::BrainstormParser.answer_header(question_n)}#{newline}" ] +
                     answer_body(answer_text, newline).lines
        lines[0...insert_idx] + slot_lines + lines[insert_idx..].to_a
      end
      private_class_method :insert_answer_slot

      # Locate the empty A-section to fill for question_n. Q-context-
      # aware: walks forward from the Q{n} header that the parser
      # identified as the target (first unanswered Q with that number
      # in document order) and returns the first empty A-section before
      # the next block boundary (Q / Round / marker).
      #
      # Tolerates off-by-one A-numbers (agents occasionally emit
      # `### A2.` after `### Q1.`) without misattributing: the slot is
      # selected by POSITION within the Q-block, not by A-number.
      #
      # Previously this was a two-step scan: strict by-number first,
      # then by-position fallback. The strict scan ignored Q-context
      # and could cross round boundaries — a brainstorm.md with empty
      # `### A1.` in Round 1 (still unanswered) and Round 2's `### A1.`
      # would route operator's Round-2 answer into Round-1's slot. The
      # combined Q-context-aware function below resolves that by
      # always anchoring the scan to the parser-identified target Q's
      # line, then walking forward.
      def find_empty_answer_slot(lines, question_n, parsed)
        q_idx = target_question_line_index(lines, parsed, question_n)
        return nil unless q_idx

        scan = q_idx + 1
        while scan < lines.length
          stripped = lines[scan].chomp
          break if stripped =~ QUESTION_RE || stripped =~ ROUND_RE || stripped =~ MARKER_RE
          return empty_slot_starting_at(lines, scan) if ANSWER_RE.match?(stripped)

          scan += 1
        end
        nil
      end
      private_class_method :find_empty_answer_slot

      # Map the parser's view of "first unanswered Q with this number"
      # back to a line index in the raw file. Multiple Q{n} can exist
      # (e.g. each new Round restarts numbering); we want the one the
      # parser believes is still awaiting an answer.
      def target_question_line_index(lines, parsed, question_n)
        matching = parsed.select { |q| q.n == question_n }
        target_position = matching.find_index { |q| q.answer.nil? }
        return nil unless target_position

        seen = 0
        lines.each_with_index do |line, idx|
          match = QUESTION_RE.match(line.chomp)
          next unless match && match[1].to_i == question_n
          return idx if seen == target_position

          seen += 1
        end
        nil
      end
      private_class_method :target_question_line_index

      # Given an index pointing at an `### A{x}.` line, return the slot
      # envelope iff the body (until the next block boundary) is empty.
      def empty_slot_starting_at(lines, idx)
        body_end = idx + 1
        body = []
        while body_end < lines.length && !block_boundary?(lines[body_end])
          body << lines[body_end]
          body_end += 1
        end
        return nil unless body.join.strip.empty?

        { answer_line_index: idx, body_end_index: body_end }
      end
      private_class_method :empty_slot_starting_at

      def block_boundary?(line)
        stripped = line.chomp
        QUESTION_RE.match?(stripped) || ROUND_RE.match?(stripped) || MARKER_RE.match?(stripped)
      end
      private_class_method :block_boundary?

      def answer_body(answer_text, newline)
        text = answer_text.to_s.rstrip
        text.empty? ? newline : "#{text}#{newline}"
      end
      private_class_method :answer_body

      def newline_for(content)
        content.include?("\r\n") ? "\r\n" : "\n"
      end
      private_class_method :newline_for
    end
  end
end
