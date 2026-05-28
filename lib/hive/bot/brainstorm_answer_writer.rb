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

      QUESTION_RE = /\A###\s+Q(\d+)\.\s*/
      ANSWER_RE = /\A###\s+A(\d+)\.\s*\z/
      ROUND_RE = /\A##\s+Round\s+\d+\b/i
      MARKER_RE = /\A<!--\s*[A-Z_]+(?:\s+[^<>]*?)?\s*-->\s*\z/

      LOCK_RETRY_DEADLINE_SEC = 5
      LOCK_RETRY_SLEEP_SEC = 0.05

      def append!(brainstorm_path:, question_n:, answer_text:, logger: nil)
        task_folder = File.dirname(brainstorm_path)
        raise Hive::InvalidTaskPath, "task folder does not exist: #{task_folder}" unless Dir.exist?(task_folder)

        deadline = Time.now + LOCK_RETRY_DEADLINE_SEC
        result = nil
        last_holder = nil
        loop do
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
        end

        raise "BrainstormAnswerWriter returned unknown result #{result.inspect}" unless RESULTS.include?(result)

        result
      end

      # Returns [result_symbol, holder_metadata_or_nil].
      # holder_metadata is only set when the call FAILED to acquire the lock,
      # in which case result is nil.
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
          slot = find_empty_answer_slot(lines, question_n)
          # Q{n} is in parsed (the earlier guard verified this), but
          # no empty A-section is locatable between Q{n} and the next
          # boundary — either the agent forgot to emit `### A{n}.`,
          # the answer was already filled and we missed it via the
          # parsed view, or the file is genuinely malformed. Return a
          # distinct symbol so the supervisor can render a helpful
          # message (not "Question N was not found").
          next :answer_slot_missing unless slot

          newline = newline_for(content)
          if slot[:answer_line_index] >= 0 && !lines[slot[:answer_line_index]].to_s.end_with?(newline)
            lines[slot[:answer_line_index]] = "#{lines[slot[:answer_line_index]]}#{newline}"
          end

          answer_lines = answer_body(answer_text, newline).lines
          new_lines = lines[0..slot[:answer_line_index]] + answer_lines + lines[slot[:body_end_index]..].to_a
          Hive::Markers.write_atomic(brainstorm_path, new_lines.join)
          :written
        end
        [ result, nil ]
      rescue Hive::ConcurrentRunError => e
        [ nil, e.holder ]
      rescue Errno::ENOENT
        [ nil, nil ]
      end
      private_class_method :try_append

      # Locate the empty A-section to fill for question_n. Tries strict
      # number-matching first (`### A{n}.` line whose body is empty),
      # then falls back to "first empty A-section between the Q{n}
      # header and the next block boundary" — agents very occasionally
      # emit an off-by-one A header (e.g. `### A2.` immediately after
      # `### Q1.` for a fresh round). The parser tolerates that case
      # (see brainstorm_parser.rb#parse_text); this writer matches.
      def find_empty_answer_slot(lines, question_n)
        lines.each_with_index do |line, idx|
          match = ANSWER_RE.match(line.chomp)
          next unless match && match[1].to_i == question_n

          slot = empty_slot_starting_at(lines, idx)
          return slot if slot
        end

        find_empty_answer_slot_by_position(lines, question_n)
      end
      private_class_method :find_empty_answer_slot

      # Find the Q{n} line, then scan forward for the first A-section
      # before the next block boundary (next Q / Round / marker). If
      # that A-section is empty, it's our slot — number be damned.
      def find_empty_answer_slot_by_position(lines, question_n)
        q_idx = lines.index do |line|
          match = QUESTION_RE.match(line.chomp)
          match && match[1].to_i == question_n
        end
        return nil unless q_idx

        scan = q_idx + 1
        while scan < lines.length
          stripped = lines[scan].chomp
          break if stripped =~ QUESTION_RE || stripped =~ ROUND_RE || stripped =~ MARKER_RE
          if ANSWER_RE.match?(stripped)
            return empty_slot_starting_at(lines, scan)
          end
          scan += 1
        end
        nil
      end
      private_class_method :find_empty_answer_slot_by_position

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
