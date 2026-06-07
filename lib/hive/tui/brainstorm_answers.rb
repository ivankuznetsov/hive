require "hive"
require "hive/tui/debug"

module Hive
  module Tui
    # Pure markdown-parsing predicate over a brainstorm.md state file.
    # Returns true only when the latest `## Round N` block has every
    # numbered question paired with a non-empty numbered answer.
    #
    # Heading-form tolerance:
    #   The canonical contract in `templates/brainstorm_prompt.md.erb`
    #   uses `### Q{n}.` for questions and `### A{n}.` for answers,
    #   but the `/ce-brainstorm` skill (which the
    #   prompt invokes for Round 2+) emits `### Q{n} answer.` instead
    #   of `### A{n}.`. Both forms are accepted as answers so the
    #   parser does not refuse on legitimate agent output.
    #
    # Conservative on ambiguity:
    # - duplicate Q/A numbers within the same round → not complete
    # - readlines / encoding errors → not complete (Debug.log + return false)
    # - no `## Round` heading → not complete
    #
    # Markdown-shape-aware:
    # - lines inside fenced code blocks (``` or ~~~) are not live structure
    # - 4+ space indentation falls outside CommonMark ATX-heading territory,
    #   so heading regexes accept only 0-3 leading spaces
    # - HTML comments (`<!-- WAITING -->` etc.) are stripped from answer
    #   bodies before emptiness check; comment lines do not terminate
    #   answer collection
    module BrainstormAnswers
      module_function

      ROUND_HEADING       = /\A {0,3}##\s+Round\s+(\d+)\b/i.freeze
      ANSWER_HEAD_LONG    = /\A {0,3}###\s+Q(\d+)\s+answer\b/i.freeze
      ANSWER_HEAD_SHORT   = /\A {0,3}###\s+A(\d+)\b/i.freeze
      QUESTION_HEAD       = /\A {0,3}###\s+Q(\d+)\b/i.freeze
      QA_HEADING_ANY      = /\A {0,3}###\s+(?:Q\d+\s+answer|[QA]\d+)\b/i.freeze
      ANSWER_HEAD_PREFIX  = /\A {0,3}###\s+(?:A\d+\s*\.?|Q\d+\s+answer\s*\.?)\s*/i.freeze
      H2_HEADING          = /\A {0,3}##\s+/.freeze
      FENCE_LINE          = /\A {0,3}(```|~~~)/.freeze
      HTML_COMMENT        = /<!--.*?-->/m.freeze

      # Public entrypoint. Reads `path`, returns true iff the latest
      # round in the file has every numbered question paired with a
      # numbered answer whose body is non-empty after stripping
      # HTML comments and whitespace.
      #
      # The I/O rescue lives in `read_lines` so that any genuine
      # `ArgumentError`/`StandardError` from the parser body surfaces
      # as a real crash during dev/test rather than silently turning
      # into "auto-continue refuses to fire."
      def complete?(path)
        lines = read_lines(path)
        return false if lines.nil?

        live = live_structure_mask(lines)
        round_start = latest_round_start(lines, live)
        return false if round_start.nil?

        questions, answers, q_dup, a_dup = numbered_headings(lines, live, round_start + 1)
        return false if q_dup || a_dup
        return false if questions.empty? || answers.empty?
        return false unless questions.keys.sort == answers.keys.sort

        answers.values.all? { |idx| answer_filled?(lines, live, idx) }
      end

      # `.scrub` replaces invalid byte sequences with `?` so the
      # parser's `String#match?` calls cannot raise ArgumentError on
      # garbled input. Returns nil on file-level failure so the caller
      # can short-circuit without a parser-body rescue.
      def read_lines(path)
        File.readlines(path, chomp: true).map(&:scrub)
      rescue SystemCallError, EncodingError, IOError => e
        Hive::Tui::Debug.log("brainstorm_answers", "read failed: #{e.class}: #{e.message}")
        nil
      end
      private_class_method :read_lines

      # Boolean array, parallel to `lines`, marking which lines are
      # eligible to count as live structure. A line is "dead" when
      # it sits inside a fenced code block (``` or ~~~). The fence
      # delimiters themselves are also marked dead so a stray fence
      # line never matches a heading regex.
      def live_structure_mask(lines)
        mask = Array.new(lines.length, true)
        in_fence = false
        lines.each_with_index do |line, idx|
          if line.match?(FENCE_LINE)
            mask[idx] = false
            in_fence = !in_fence
          elsif in_fence
            mask[idx] = false
          end
        end
        mask
      end
      private_class_method :live_structure_mask

      # Picks the round with the highest N. Ties (the same N appearing
      # twice) are broken by file position — the later occurrence wins,
      # matching "user just edited the most recent block" intent.
      def latest_round_start(lines, live)
        best_n = -1
        best_idx = nil
        lines.each_with_index do |line, idx|
          next unless live[idx]
          next unless (m = line.match(ROUND_HEADING))

          n = m[1].to_i
          next if n < best_n

          best_n = n
          best_idx = idx
        end
        best_idx
      end
      private_class_method :latest_round_start

      # Walk the round body once, collecting numbered question and
      # answer heading line indices keyed by digit. Returns
      # `[questions, answers, q_dup, a_dup]`. Stops at the next `## `
      # (sibling round) so headings from later rounds do not bleed
      # into the current round's coverage check.
      #
      # Recognized answer forms (both yield the same numeric key):
      #   `### A{n}`            (canonical, per brainstorm template)
      #   `### Q{n} answer`     (ce-brainstorm skill output for Round 2+)
      #
      # Order of `classify_qa_heading` checks matters: the long form
      # `Q{n} answer` must be tested before the plain `Q{n}` so a
      # legitimate answer heading is not double-matched as a question.
      def numbered_headings(lines, live, start_idx)
        questions = {}
        answers = {}
        q_dup = false
        a_dup = false
        (start_idx...lines.length).each do |idx|
          next unless live[idx]
          line = lines[idx]
          break if line.match?(H2_HEADING)

          kind, num = classify_qa_heading(line)
          next if kind.nil?

          target = kind == :q ? questions : answers
          if target.key?(num)
            kind == :q ? q_dup = true : a_dup = true
          else
            target[num] = idx
          end
        end
        [ questions, answers, q_dup, a_dup ]
      end
      private_class_method :numbered_headings

      def classify_qa_heading(line)
        if (m = line.match(ANSWER_HEAD_LONG))
          [ :a, m[1] ]
        elsif (m = line.match(ANSWER_HEAD_SHORT))
          [ :a, m[1] ]
        elsif (m = line.match(QUESTION_HEAD))
          [ :q, m[1] ]
        end
      end
      private_class_method :classify_qa_heading

      # An answer is filled when the heading line plus the body up to
      # the next Q/A or `## ` heading contains at least one
      # non-whitespace, non-HTML-comment character. Comment lines do
      # NOT terminate body collection; HTML comments are stripped from
      # the joined body before the emptiness check, so a trailing
      # `<!-- WAITING -->` or an in-line `<!-- thinking -->` mid-answer
      # never confuse the predicate.
      def answer_filled?(lines, live, heading_idx)
        heading_text = lines[heading_idx].sub(ANSWER_HEAD_PREFIX, "")
        stop_idx = next_section_break(lines, live, heading_idx + 1) || lines.length
        # Zero out non-live lines (fenced code blocks) so content
        # inside ``` cannot pad an otherwise-empty answer body.
        body_lines = (heading_idx + 1...stop_idx).map { |i| live[i] ? lines[i] : "" }
        body = body_lines.join("\n")
        strip_comments_and_whitespace("#{heading_text}\n#{body}").length.positive?
      end
      private_class_method :answer_filled?

      # The next index that ends an answer body: a sibling Q/A heading
      # (live structure only) or an h2 (`## `). Lines inside fenced
      # code blocks count as body, not as boundaries.
      def next_section_break(lines, live, start_idx)
        (start_idx...lines.length).find do |idx|
          next false unless live[idx]

          lines[idx].match?(QA_HEADING_ANY) || lines[idx].match?(H2_HEADING)
        end
      end
      private_class_method :next_section_break

      def strip_comments_and_whitespace(text)
        text.gsub(HTML_COMMENT, "").strip
      end
      private_class_method :strip_comments_and_whitespace
    end
  end
end
