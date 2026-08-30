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
      RESERVED_RE = /hive-suggestion:v1/.freeze
      STRUCTURAL_BOUNDARY_RE = /\A(?: {0,3}\#{1,3}\s+(?:Round\s+\d+|[QA]\d+\b)|<!--\s*[A-Z_]+)/i.freeze

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

        body = text.to_s.scrub.gsub("\r\n", "\n").gsub("\r", "\n").rstrip
        raise InvalidState, "suggestion envelope body must not be empty" if body.empty?

        "<!-- hive-suggestion:v1 binding=#{binding} -->\n#{body}\n<!-- /hive-suggestion:v1 -->\n"
      end

      def regions(source)
        strip(source).regions
      end

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
            corrupt ||= line.match?(RESERVED_RE)
            kept << line unless line.match?(RESERVED_RE)
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
    end
  end
end
