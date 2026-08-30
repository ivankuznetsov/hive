# frozen_string_literal: true

require "hive/brainstorm_suggestions"

module Hive
  module BrainstormSuggestions
    # The sole markdown projection grammar. Candidate bodies are ordinary text
    # between exact comment delimiters so removing the delimiters adopts the
    # byte-identical body. Any malformed reserved region is stripped as
    # advisory through the next Q/A boundary and is never parsed as an answer.
    module Envelope
      OPEN_RE = /\A<!-- hive-suggestion:v1 binding=([0-9a-f]{64}) -->\r?\n?\z/.freeze
      CLOSE_RE = /\A<!-- \/hive-suggestion:v1 -->\r?\n?\z/.freeze
      DELIMITER_RE = /\A<!-- (?:hive-suggestion:v1 binding=[0-9a-f]{64}|\/hive-suggestion:v1) -->\r?\n?\z/.freeze
      RESERVED_TOKEN = "hive-suggestion:v1"
      RESERVED_RE = /\A[ \t]*<!--[^\r\n]*\/?hive-suggestion:v1[^\r\n]*(?:-->)?[ \t]*\r?\n?\z/i.freeze
      RESERVED_OPEN_RE = /\A[ \t]*<!--[ \t]*hive-suggestion:v1\b/i.freeze
      STRUCTURAL_BOUNDARY_RE = /\A(?: {0,3}\#{1,3}\s+(?:Round\s+\d+|[QA]\d+\b)|<!--\s*[A-Z_]+)/i.freeze
      MAX_SCAN_BYTES = 2 * 1024 * 1024

      Region = Struct.new(:binding, :text, :source, :start_offset, :end_offset, keyword_init: true)
      StripResult = Struct.new(:text, :regions, :corrupt, keyword_init: true) do
        def corrupt?
          corrupt
        end
      end

      module_function

      def render(binding:, text:)
        unless binding.to_s.match?(/\A[0-9a-f]{64}\z/)
          raise InvalidState, "suggestion envelope binding must be a SHA-256 digest"
        end

        body = text.to_s
        unless body.valid_encoding? && !body.match?(Safety::BARE_CR_RE)
          raise InvalidState, "suggestion envelope body must use canonical line endings"
        end
        body = body.gsub("\r\n", "\n")
        raise InvalidState, "suggestion envelope body must not be empty" if body.empty?

        "<!-- hive-suggestion:v1 binding=#{binding} -->\n#{body}\n<!-- /hive-suggestion:v1 -->\n"
      end

      def regions(source)
        strip(source).regions
      end

      # Frozen pre-feature answer view used only by the downgrade fence. It
      # intentionally does not call #strip, so malformed advisory grammar
      # cannot hide operator-visible changes from cleanup verification.
      def legacy_answers(source)
        answers = []
        current = nil
        mode = nil
        source.to_s.gsub("\r\n", "\n").gsub("\r", "\n").each_line(chomp: true) do |line|
          if line.match?(/\A##\s+Round\s+[1-9]\d*\b/i) || line.match?(/\A###\s+Q[1-9]\d*\./)
            answers << legacy_answer(current) if current
            current = line.match?(/\A###\s+Q/) ? [] : nil
            mode = nil
          elsif current && line.match?(/\A###\s+A[1-9]\d*\.\s*(?:<!-- hive-answer:v1 -->)?\s*\z/)
            current = []
            mode = :answer
          elsif current && mode == :answer && !line.match?(/\A<!--\s*[A-Z_]+(?:\s+[^<>]*?)?\s*-->\s*\z/)
            current << line
          end
        end
        answers << legacy_answer(current) if current
        answers
      end

      def legacy_answer(lines)
        body = Array(lines).dup
        body.pop while body.last&.strip&.empty?
        value = body.join("\n").strip
        value unless value.empty?
      end
      private_class_method :legacy_answer

      def strip(source)
        lines = source.to_s.lines
        kept = []
        found = []
        corrupt = false
        offset = 0
        index = 0

        while index < lines.length
          line = lines[index]
          match = OPEN_RE.match(line)
          unless match
            reserved = line.match?(RESERVED_RE)
            corrupt ||= reserved
            if reserved && line.match?(RESERVED_OPEN_RE)
              index, consumed = consume_corrupt_region(lines, index)
              offset += consumed
              next
            end
            kept << line unless reserved
            offset += line.bytesize
            index += 1
            next
          end

          start_offset = offset
          binding = match[1]
          region_lines = [ line ]
          body_lines = []
          region_corrupt = false
          index += 1
          offset += line.bytesize
          closed = false

          while index < lines.length
            current = lines[index]
            if CLOSE_RE.match?(current)
              region_lines << current
              offset += current.bytesize
              index += 1
              closed = true
              break
            end
            if OPEN_RE.match?(current) || current.match?(RESERVED_RE)
              region_corrupt = true
              region_lines << current
              offset += current.bytesize
              index += 1
              next
            end
            break if current.match?(STRUCTURAL_BOUNDARY_RE)

            body_lines << current
            region_lines << current
            offset += current.bytesize
            index += 1
          end

          region_corrupt ||= !closed
          corrupt ||= region_corrupt
          unless region_corrupt
            found << Region.new(
              binding: binding,
              text: body_lines.join.sub(/\r?\n\z/, ""),
              source: region_lines.join,
              start_offset: start_offset,
              end_offset: offset
            )
          end
        end

        StripResult.new(text: kept.join, regions: found.freeze, corrupt: corrupt)
      end

      def consume_corrupt_region(lines, start_index)
        index = start_index
        bytes = 0
        while index < lines.length
          current = lines[index]
          break if index > start_index && current.match?(STRUCTURAL_BOUNDARY_RE)

          bytes += current.bytesize
          index += 1
          break if index > start_index + 1 &&
                   (CLOSE_RE.match?(current) ||
                    (current.match?(RESERVED_RE) && !current.match?(RESERVED_OPEN_RE)))
        end
        [ index, bytes ]
      end
      private_class_method :consume_corrupt_region
    end
  end
end
