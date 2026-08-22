# frozen_string_literal: true

require "base64"
require "digest"

module Hive
  # Pure parser for the brainstorm Q&A file format (`brainstorm.md`):
  # `## Round N` sections containing `### Q{n}.` / `### A{n}.` pairs.
  # Lives at the top `Hive::` namespace (not `Hive::Bot::`) because both
  # the Telegram bot (answer writer / next-question prompt) and the
  # daemon (gating auto-resume until every question is answered) need it.
  # `Hive::Bot::BrainstormParser` remains as a back-compat alias.
  module BrainstormParser
    Question = Struct.new(
      :round, :n, :text, :answer, :answer_encoding,
      keyword_init: true
    ) do
      def answered?
        !answer.nil?
      end

      def controller_bound_answer?
        answered? && answer_encoding == :v1
      end
    end

    ROUND_RE = /\A##\s+Round\s+([1-9]\d*)\b/i
    QUESTION_RE = /\A###\s+Q([1-9]\d*)\.\s*(.*)\z/
    ANSWER_ENCODING_V1 = "<!-- hive-answer:v1 -->".freeze
    ANSWER_RE = /\A###\s+A([1-9]\d*)\.\s*(#{Regexp.escape(ANSWER_ENCODING_V1)})?\s*\z/
    MARKER_RE = /\A<!--\s*[A-Z_]+(?:\s+[^<>]*?)?\s*-->\s*\z/
    ANSWER_ESCAPE_PREFIX = "\\hive-answer-v1:".freeze

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
            current[:answer_encoding] = :v1 if match[2]
            mode = :answer
          end
          next
        end

        # Stage markers delimit the Q/A block but are not part of either the
        # question presented to an operator or its fingerprint. In particular,
        # a final question with no A-header must keep the same fingerprint after
        # the writer repairs its slot immediately before `<!-- WAITING -->`.
        next if MARKER_RE.match?(line)

        case mode
        when :question
          current[:question_lines] << line if current
        when :answer
          current[:answer_lines] << line if current
        end
      end

      finalize(questions, current)
      # Preserve the file's physical order. Question numbers restart between
      # rounds and malformed-but-recoverable files can contain non-monotonic
      # numbering; callers that bind a user reply need the actual document
      # position rather than a synthetic sort order.
      questions
    end

    def next_unanswered_question(parsed)
      parsed.find { |question| question.answer.nil? }
    end

    def unanswered_questions(parsed)
      parsed.select { |question| question.answer.nil? }
    end

    # Normalize layout-only differences before binding a presented question to
    # a durable fingerprint. NFC closes canonically-equivalent Unicode forms
    # without compatibility-folding distinct glyphs such as ①/1 or x²/x2;
    # whitespace collapsing lets harmless markdown reflow relocate a reply.
    # Wording, compatibility characters, and case remain significant so a
    # materially edited question fails closed instead of receiving a stale
    # answer.
    def normalize_question_text(text)
      text.to_s.scrub.unicode_normalize(:nfc).gsub(/[[:space:]]+/, " ").strip
    end

    def question_fingerprint(text)
      Digest::SHA256.hexdigest(
        [ "hive-brainstorm-question-v1", normalize_question_text(text) ].join("\0")
      )
    end

    # Canonical answer heading string shared by the writer fallback and any
    # future renderer.
    def answer_header(n)
      "### A#{n}."
    end

    def encoded_answer_header(n)
      "#{answer_header(n)} #{ANSWER_ENCODING_V1}"
    end

    def finalize(out, current)
      return unless current

      out << Question.new(
        round: current[:round],
        n: current[:n],
        text: clean_body(current[:question_lines]),
        answer: clean_answer(current[:answer_lines], encoding: current[:answer_encoding]),
        answer_encoding: current[:answer_encoding]
      )
    end
    private_class_method :finalize

    def clean_body(lines)
      Array(lines).join("\n").strip
    end
    private_class_method :clean_body

    def clean_answer(lines, encoding: nil)
      return nil if lines.nil?

      body_lines = Array(lines).dup
      body_lines.pop while (last = body_lines.last) && (last.strip.empty? || MARKER_RE.match?(last))
      body_lines.map! { |line| restore_answer_line(line) } if encoding == :v1
      body = body_lines.join("\n").strip
      body.empty? ? nil : body
    end
    private_class_method :clean_answer

    # Only decode the explicit v1 envelope written by BrainstormAnswerWriter.
    # Older brainstorm files stored literal answer text, including doubled
    # backslashes and strings such as `\&lt;!--`; treating those as an implicit
    # escape format changes settled answers and can create false idempotency
    # conflicts.
    def restore_answer_line(line)
      return line unless line.start_with?(ANSWER_ESCAPE_PREFIX)

      encoded = line.delete_prefix(ANSWER_ESCAPE_PREFIX)
      Base64.urlsafe_decode64(encoded)
    rescue ArgumentError
      line
    end
    private_class_method :restore_answer_line

    def normalize_newlines(text)
      text.to_s.gsub("\r\n", "\n").gsub("\r", "\n")
    end
    private_class_method :normalize_newlines
  end
end
