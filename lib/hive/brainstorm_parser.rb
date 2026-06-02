# frozen_string_literal: true

module Hive
  # Pure parser for the brainstorm Q&A file format (`brainstorm.md`):
  # `## Round N` sections containing `### Q{n}.` / `### A{n}.` pairs.
  # Lives at the top `Hive::` namespace (not `Hive::Bot::`) because both
  # the Telegram bot (answer writer / next-question prompt) and the
  # daemon (gating auto-resume until every question is answered) need it.
  # `Hive::Bot::BrainstormParser` remains as a back-compat alias.
  module BrainstormParser
    Question = Struct.new(:round, :n, :text, :answer, keyword_init: true) do
      def answered?
        !answer.nil?
      end
    end

    ROUND_RE = /\A##\s+Round\s+(\d+)\b/i
    QUESTION_RE = /\A###\s+Q(\d+)\.\s*(.*)\z/
    ANSWER_RE = /\A###\s+A(\d+)\.\s*\z/
    MARKER_RE = /\A<!--\s*[A-Z_]+(?:\s+[^<>]*?)?\s*-->\s*\z/

    module_function

    # Read + parse a brainstorm file. Total by construction: a missing /
    # unreadable file and invalid UTF-8 both degrade to a best-effort
    # parse rather than raising. This matters because the file is read
    # concurrently — the Telegram bot appends answers while the daemon
    # parses to gate auto-resume — so a torn mid-append read (a split
    # multibyte boundary) must not raise. `scrub` replaces invalid bytes
    # with U+FFFD; a partially-written answer body then simply looks
    # unanswered for that one tick (the safe direction).
    def parse(path)
      raw = begin
        File.read(path, encoding: "UTF-8")
      rescue Errno::ENOENT, Errno::EACCES, IOError
        ""
      end
      parse_text(raw.scrub)
    end

    def parse_text(text)
      questions = []
      current_round = nil
      current = nil
      mode = nil

      normalize_newlines(text).each_line(chomp: true) do |line|
        if (match = ROUND_RE.match(line))
          finalize(questions, current)
          current = nil
          mode = nil
          current_round = match[1].to_i
          next
        end

        if (match = QUESTION_RE.match(line))
          finalize(questions, current)
          current = {
            round: current_round,
            n: match[1].to_i,
            question_lines: [ match[2] ],
            answer_lines: nil
          }
          mode = :question
          next
        end

        if (match = ANSWER_RE.match(line))
          # The brainstorm agent very occasionally emits an
          # off-by-one A-header (e.g. `### A2.` immediately after
          # `### Q1.` for a fresh Round 2). The strict
          # `current[:n] == match[1].to_i` check silently dropped
          # such lines, leaving the Q permanently un-answerable from
          # the bot — and worse, gave the operator a misleading
          # "Question N was not found" reply. Accept the FIRST A
          # section under the current Q as that Q's answer slot
          # regardless of its number; a subsequent A line under the
          # same Q (whether duplicate-numbered or not) is still
          # ignored. The writer's `find_empty_answer_slot` has a
          # matching lenient fallback so the answer lands in the
          # actual slot on disk.
          if current && current[:answer_lines].nil?
            current[:answer_lines] = []
            mode = :answer
          end
          next
        end

        case mode
        when :question
          current[:question_lines] << line if current
        when :answer
          current[:answer_lines] << line if current
        end
      end

      finalize(questions, current)
      questions.sort_by { |question| [ question.round || 0, question.n ] }
    end

    def next_unanswered_question(parsed)
      parsed.find { |question| question.answer.nil? }
    end

    def unanswered_questions(parsed)
      parsed.select { |question| question.answer.nil? }
    end

    def question_for(parsed, question_n)
      parsed.find { |question| question.n == question_n }
    end

    # Canonical heading strings. Centralized here so supervisor copy,
    # writer fallback messages, and any future renderer share one
    # source of truth. If the brainstorm.md format ever changes (e.g.
    # `### Q{n}.` becomes `### Q{n}:`), these are the single place to
    # update.
    def question_header(n)
      "### Q#{n}."
    end

    def answer_header(n)
      "### A#{n}."
    end

    def finalize(out, current)
      return unless current

      out << Question.new(
        round: current[:round],
        n: current[:n],
        text: clean_body(current[:question_lines]),
        answer: clean_answer(current[:answer_lines])
      )
    end
    private_class_method :finalize

    def clean_body(lines)
      Array(lines).join("\n").strip
    end
    private_class_method :clean_body

    def clean_answer(lines)
      return nil if lines.nil?

      body_lines = Array(lines).dup
      body_lines.pop while (last = body_lines.last) && (last.strip.empty? || MARKER_RE.match?(last))
      body = body_lines.join("\n").strip
      body.empty? ? nil : body
    end
    private_class_method :clean_answer

    def normalize_newlines(text)
      text.to_s.gsub("\r\n", "\n").gsub("\r", "\n")
    end
    private_class_method :normalize_newlines
  end
end
