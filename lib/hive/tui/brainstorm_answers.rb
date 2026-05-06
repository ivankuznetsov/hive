require "hive"
require "hive/tui/debug"

module Hive
  module Tui
    # Pure markdown-parsing predicate over a brainstorm.md state file.
    # Returns true only when the latest `## Round N` block has every
    # `### Qn` paired with a non-empty `### An`, mirroring the contract
    # in `templates/brainstorm_prompt.md.erb`.
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

      ROUND_HEADING = /\A {0,3}##\s+Round\s+(\d+)\b/i.freeze
      QA_HEADING    = /\A {0,3}###\s+([QA])(\d+)\b/i.freeze
      ANSWER_HEAD_PREFIX = /\A {0,3}###\s+A\d+\s*\.?\s*/i.freeze
      H2_HEADING    = /\A {0,3}##\s+/.freeze
      FENCE_LINE    = /\A {0,3}(```|~~~)/.freeze
      HTML_COMMENT  = /<!--.*?-->/m.freeze

      # Public entrypoint. Reads `path`, returns true iff the latest
      # round in the file has every numbered question paired with a
      # numbered answer whose body is non-empty after stripping
      # HTML comments and whitespace.
      def complete?(path)
        lines = File.readlines(path, chomp: true)
        live = live_structure_mask(lines)
        round_start = latest_round_start(lines, live)
        return false if round_start.nil?

        questions, q_dup = numbered_headings(lines, live, round_start + 1, "Q")
        answers,   a_dup = numbered_headings(lines, live, round_start + 1, "A")
        return false if q_dup || a_dup
        return false if questions.empty? || answers.empty?
        return false unless questions.keys.sort == answers.keys.sort

        answers.values.all? { |idx| answer_filled?(lines, live, idx) }
      rescue SystemCallError, EncodingError, IOError, ArgumentError => e
        # ArgumentError covers `invalid byte sequence in UTF-8` raised by
        # String#match? on garbled bytes — same conservative direction
        # as the Errno paths: refuse to auto-continue on a file we
        # cannot reliably parse.
        Hive::Tui::Debug.log("brainstorm_answers", "completeness check failed: #{e.class}: #{e.message}")
        false
      end

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

      # Walk forward from `start_idx` collecting `### Qn` or `### An`
      # heading line indices keyed by their digit. Returns
      # `[Hash{String => Integer}, duplicates_seen?]`. Stops at the
      # next `## ` (sibling round) so headings from later rounds do
      # not bleed into the current round's coverage check.
      def numbered_headings(lines, live, start_idx, prefix)
        headings = {}
        duplicates = false
        (start_idx...lines.length).each do |idx|
          next unless live[idx]
          line = lines[idx]
          break if line.match?(H2_HEADING)
          next unless (m = line.match(QA_HEADING))
          next unless m[1].casecmp?(prefix)

          if headings.key?(m[2])
            duplicates = true
          else
            headings[m[2]] = idx
          end
        end
        [ headings, duplicates ]
      end
      private_class_method :numbered_headings

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

          lines[idx].match?(QA_HEADING) || lines[idx].match?(H2_HEADING)
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
