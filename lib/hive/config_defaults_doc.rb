# frozen_string_literal: true

require "pp"

module Hive
  # Projects the runtime-owned configuration defaults into the one managed
  # region of wiki/modules/config.md. Rendering is deliberately pure so the
  # maintainer writer and the read-only drift check can share byte-for-byte
  # output.
  module ConfigDefaultsDoc
    WIKI_PAGE = File.join("wiki", "modules", "config.md")
    BEGIN_MARKER = "<!-- BEGIN GENERATED: Config::DEFAULTS -->"
    END_MARKER = "<!-- END GENERATED: Config::DEFAULTS -->"
    BEGIN_MARKER_CANDIDATE = /<!--[^\r\n]*\bBEGIN\b[^\r\n]*\bGENERATED\b[^\r\n]*Config::DEFAULTS/i
    END_MARKER_CANDIDATE = /<!--[^\r\n]*\bEND\b[^\r\n]*\bGENERATED\b[^\r\n]*Config::DEFAULTS/i
    SERIALIZER_WIDTH = 80

    class InvalidRegionError < ArgumentError; end

    module_function

    # Render every supplied default as a stable Ruby literal. PP receives a
    # fixed width and a string destination, so terminal width and TTY state
    # cannot influence the layout.
    def generated_reference(defaults = Hive::Config::DEFAULTS)
      literal = PP.pp(defaults, +"", SERIALIZER_WIDTH).delete_suffix("\n")
      "```ruby\n#{literal}\n```\n".b
    end

    # Validate the complete page before replacing the managed region. Only an
    # exact, unique, ordered pair of standalone LF-terminated marker lines is
    # accepted; surrounding bytes are returned unchanged.
    def render(content, defaults: Hive::Config::DEFAULTS)
      page = content.b
      region_start, region_end = validated_region(page)
      prefix = page.byteslice(0, region_start)
      suffix = page.byteslice(region_end, page.bytesize - region_end)
      generated_region = "#{BEGIN_MARKER}\n#{generated_reference(defaults)}#{END_MARKER}\n".b

      prefix + generated_region + suffix
    end

    # Refresh the repository page only after the complete binary input has
    # validated and rendered successfully. A false result is a no-op: the
    # file is not opened for writing and its metadata remains untouched.
    def regenerate(project_root:, defaults: Hive::Config::DEFAULTS)
      path = File.join(project_root, WIKI_PAGE)
      content = File.binread(path)
      updated = render(content, defaults:)
      return false if updated == content

      File.binwrite(path, updated)
      true
    end

    def validated_region(page)
      begin_line = "#{BEGIN_MARKER}\n".b
      end_line = "#{END_MARKER}\n".b
      begin_candidates = page.scan(BEGIN_MARKER_CANDIDATE).length
      end_candidates = page.scan(END_MARKER_CANDIDATE).length
      begin_occurrences = page.scan(BEGIN_MARKER.b).length
      end_occurrences = page.scan(END_MARKER.b).length
      begin_lines = page.each_line("\n").count { |line| line == begin_line }
      end_lines = page.each_line("\n").count { |line| line == end_line }
      begin_at = page.index(begin_line)
      end_at = page.index(end_line)

      valid = begin_candidates == 1 && end_candidates == 1 &&
              begin_occurrences == 1 && end_occurrences == 1 &&
              begin_lines == 1 && end_lines == 1 && begin_at < end_at
      unless valid
        raise InvalidRegionError,
              "#{WIKI_PAGE} must contain exactly one standalone LF-terminated " \
              "#{BEGIN_MARKER} line followed by exactly one #{END_MARKER} line"
      end

      [ begin_at, end_at + end_line.bytesize ]
    end
    private_class_method :validated_region
  end
end
