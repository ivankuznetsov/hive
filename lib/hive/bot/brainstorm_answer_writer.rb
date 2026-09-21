require "base64"
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

      # The physical line array all writer surgery operates on: the
      # parser's `document_lines` (newline-normalized, chomped — exactly
      # the array the parser's `question_line_index` / `block_end_index` /
      # `answer_line_index` fields index into), re-terminated with `\n` so
      # a plain join reproduces the document. Parser location fields and
      # writer line surgery therefore share one definition of "a line".
      def write_document_lines(content)
        Hive::BrainstormParser.document_lines(content).map { |line| "#{line}\n" }
      end
      private_class_method :write_document_lines

      LOCK_RETRY_DEADLINE_SEC = 5
      LOCK_RETRY_SLEEP_SEC = 0.05
      MARKER_LOCK_TIMEOUT_SEC = 5

      def append!(brainstorm_path:, question_n:, answer_text:, logger: nil)
        task_folder = File.dirname(brainstorm_path)
        raise Hive::InvalidTaskPath, "task folder does not exist: #{task_folder}" unless Dir.exist?(task_folder)
        return :question_not_found unless File.exist?(brainstorm_path)

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
          # Capture the holder BEFORE the deadline check. On a loaded machine a
          # single try_append can outlast the whole retry budget, so the break
          # below fires on the very iteration that observed the holder — and
          # deferring this assignment dropped it, emitting holder: nil in the
          # one case operators most need the culprit's identity.
          last_holder = holder if holder
          break if result || Time.now >= deadline

          sleep LOCK_RETRY_SLEEP_SEC
        end

        if result.nil?
          # Emit a structured event so operators can grep the bot log to see
          # what was holding the per-task lock when the writer gave up.
          # holder fields come from Hive::Lock's task lease payload — typically
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

      # Exact-slot counterpart used by the identity-bound CLI. The caller must
      # already hold this task's lock; keeping lock acquisition outside this
      # method lets identity, stage, generation, and fingerprint validation live
      # in the same critical section as the atomic write.
      #
      # Ordinals are one-based physical document positions, so a later round's
      # Q1 can be selected without first filling an earlier round's Q1.
      def write_at_ordinal_under_lock!(brainstorm_path:, ordinal:, answer_text:)
        ordinal = begin
          Integer(ordinal)
        rescue ArgumentError, TypeError
          return :question_not_found
        end
        return :question_not_found unless ordinal.positive?

        Hive::Markers.with_markers_lock(
          brainstorm_path, create: false, timeout: MARKER_LOCK_TIMEOUT_SEC
        ) do
          # Line surgery must happen on the SAME newline-normalized line
          # array the parser indexed its location fields against
          # (`document_lines`), not on `content.lines`: a lone-\r file
          # yields more parser lines than raw lines, so index math across
          # the two would misattribute. See `write_document_lines`.
          content = File.read(brainstorm_path, encoding: "UTF-8").scrub
          lines = write_document_lines(content)
          parsed = Hive::Bot::BrainstormParser.parse_text(content)
          target = parsed[ordinal - 1]
          next :question_not_found unless target
          next :already_answered if target.answered?

          question_line_index = target.question_line_index
          next :question_not_found unless question_line_index

          slot = find_empty_answer_slot(lines, target)
          new_lines = if slot
            fill_answer_slot(lines, slot, answer_text)
          else
            insert_answer_slot_after(
              lines, question_line_index, target.block_end_index, target.n, answer_text
            )
          end
          Hive::Markers.write_atomic(brainstorm_path, join_document(new_lines, content))
          :written
        end
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
          Hive::Markers.with_markers_lock(brainstorm_path, create: false) do
            # Line surgery must happen on the SAME newline-normalized line
            # array the parser indexed its location fields against
            # (`document_lines`), not on `content.lines`: a lone-\r file
            # yields more parser lines than raw lines, so index math across
            # the two would misattribute. See `write_document_lines`.
            content = File.exist?(brainstorm_path) ? File.read(brainstorm_path, encoding: "UTF-8").scrub : ""
            lines = write_document_lines(content)
            parsed = Hive::Bot::BrainstormParser.parse_text(content)
            if !parsed.any? { |question| question.n == question_n }
              next :question_not_found
            end
            if !parsed.any? { |question| question.n == question_n && question.answer.nil? }
              next :already_answered
            end

            target = parsed.find { |question| question.n == question_n && question.answer.nil? }
            slot = find_empty_answer_slot(lines, target)
            if slot
              new_lines = fill_answer_slot(lines, slot, answer_text)
            else
              # Q{n} is unanswered (the earlier guards verified Q{n} is
              # present and its answer is nil) but has NO `### A{n}.` header
              # at all — the brainstorm agent emitted the question without a
              # fillable answer block. Rather than dead-end with
              # `:answer_slot_missing` (which left the operator unable to
              # answer and, with the daemon's answers-pending gate, held the
              # task indefinitely — issue #269), CREATE the slot at the end
              # of the Q-block and write the answer into it.
              new_lines = insert_answer_slot(lines, target, answer_text)
              next :answer_slot_missing unless new_lines
            end

            Hive::Markers.write_atomic(brainstorm_path, join_document(new_lines, content))
            :written
          end
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

      # Rebuild a brainstorm document from its lines. Every line in the
      # array is newline-terminated, so a plain join is enough; the only
      # decision made here is the line-ending style, which follows the
      # pre-write file (CRLF stays CRLF, LF stays LF) instead of being
      # decided per-inserted-line by a separate `newline_for` rule that
      # could drift from the document around it.
      def join_document(lines, content)
        text = lines.join
        content.include?("\r\n") ? text.gsub("\n", "\r\n") : text
      end
      private_class_method :join_document

      # Write `answer_text` into an existing empty `### A` slot.
      def fill_answer_slot(lines, slot, answer_text)
        answer_line = slot.fetch(:answer_line_index)
        block_end = slot.fetch(:block_end_index)

        lines[answer_line] = "#{Hive::Bot::BrainstormParser.encoded_answer_header(slot.fetch(:question_n))}\n"

        lines[0..answer_line] + answer_body(answer_text).lines + lines[block_end..].to_a
      end
      private_class_method :fill_answer_slot

      # #269: create a fresh `### A{n}.` slot for a question that has none,
      # at the end of the Q-block (just before the next Q / Round / marker
      # boundary, or EOF), and write the answer into it. Uses the parser's
      # canonical `answer_header` so the format stays in lockstep. Returns
      # the new lines, or nil when the parser could not locate the target
      # question's block span (unreachable in practice; nil routes
      # `try_append` back to the `:answer_slot_missing` fallback).
      def insert_answer_slot(lines, target, answer_text)
        return nil unless target&.question_line_index

        insert_answer_slot_after(
          lines, target.question_line_index, target.block_end_index, target.n, answer_text
        )
      end
      private_class_method :insert_answer_slot

      def insert_answer_slot_after(lines, q_idx, block_end_idx, question_n, answer_text)
        # `block_end_idx` is the parser-computed first boundary line of the
        # Q-block (or EOF), so the slot lands exactly at the block's end;
        # every line in `lines` is newline-terminated, so no
        # newline-termination repair is needed before splicing.
        insert_idx = block_end_idx || q_idx + 1

        slot_lines = [ "#{Hive::Bot::BrainstormParser.encoded_answer_header(question_n)}\n" ] +
                     answer_body(answer_text).lines
        lines[0...insert_idx] + slot_lines + lines[insert_idx..].to_a
      end
      private_class_method :insert_answer_slot_after

      # Locate the empty A-section to fill for the parser-identified target
      # question. Q-context-aware BY CONSTRUCTION: the target comes from
      # the parser (first unanswered Q with that number in document order)
      # together with its block span, so there is no writer-side re-scan
      # that could disagree with the parser about which Q header or block
      # boundary applies.
      #
      # Tolerates off-by-one A-numbers (agents occasionally emit
      # `### A2.` after `### Q1.`) without misattributing: the slot is
      # selected by POSITION within the Q-block, not by A-number.
      #
      # Previously the target line index was re-derived here by matching
      # raw lines against the parsed question list (`target_question_line_index`)
      # and the block boundary was re-derived by regex-scanning forward
      # (`block_boundary?`). The strict scan ignored Q-context and could
      # cross round boundaries — a brainstorm.md with empty `### A1.` in
      # Round 1 (still unanswered) and Round 2's `### A1.` would route the
      # operator's Round-2 answer into Round-1's slot. Anchoring on the
      # parser's location fields resolves that by construction.
      def find_empty_answer_slot(lines, target)
        return nil unless target&.question_line_index && target&.block_end_index

        a_idx = target.answer_line_index
        return nil unless a_idx && a_idx > target.question_line_index && a_idx < target.block_end_index

        body = lines[(a_idx + 1)...target.block_end_index].to_a
        return nil unless body.join.strip.empty?

        match = ANSWER_RE.match(lines[a_idx].to_s.chomp)
        {
          answer_line_index: a_idx,
          block_end_index: target.block_end_index,
          question_n: match[1].to_i
        }
      end
      private_class_method :find_empty_answer_slot

      def answer_body(answer_text)
        text = answer_text.to_s.gsub("\r\n", "\n").gsub("\r", "\n").rstrip
        return "\n" if text.empty?

        text.lines(chomp: true).map do |line|
          encoded = escape_answer_line?(line) ? encode_answer_line(line) : line
          "#{encoded}\n"
        end.join
      end
      private_class_method :answer_body

      def escape_answer_line?(line)
        line.start_with?(Hive::Bot::BrainstormParser::ANSWER_ESCAPE_PREFIX) ||
          line.include?("\\") || line.include?("<!--") || structural_heading?(line)
      end
      private_class_method :escape_answer_line?

      def encode_answer_line(line)
        encoded = Base64.urlsafe_encode64(line, padding: false)
        "#{Hive::Bot::BrainstormParser::ANSWER_ESCAPE_PREFIX}#{encoded}"
      end
      private_class_method :encode_answer_line

      def structural_heading?(line)
        ROUND_RE.match?(line) || QUESTION_RE.match?(line) || ANSWER_RE.match?(line)
      end
      private_class_method :structural_heading?
    end
  end
end
