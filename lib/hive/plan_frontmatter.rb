require "date"
require "yaml"
require "hive/dependencies"

module Hive
  module PlanFrontmatter
    MAX_FRONTMATTER_BYTES = 65_536

    Result = Data.define(:status, :data, :depends_on, :error) do
      def valid?
        %i[ok absent].include?(status)
      end
    end

    module_function

    # Edit only an assertion that already exists; the plan body is opaque.
    def edit_dependency(bytes, value)
      absent_assertion = { "present" => false, "value" => nil }
      return [ absent_assertion, bytes ] if bytes.nil?

      source = bytes.dup.force_encoding(Encoding::UTF_8)
      lines = source.lines
      return [ absent_assertion, bytes ] unless lines.first&.start_with?("---")
      raise ArgumentError, "malformed plan frontmatter" unless lines.first.match?(/\A---[ \t]*\r?\n\z/)

      closing = (1...lines.length).find { |index| lines[index].match?(/\A---[ \t]*(?:\r?\n|\z)/) }
      raise ArgumentError, "unterminated plan frontmatter" unless closing

      yaml = lines[1...closing].join
      raise ArgumentError, "oversized plan frontmatter" if yaml.bytesize > MAX_FRONTMATTER_BYTES

      document = Hive::DependencyEdit::Document.new(yaml)
      edited = document.present ? document.edit(value) : yaml
      [ document.assertion, lines.first + edited + lines[closing..].join ]
    end

    def read(path)
      frontmatter = read_frontmatter(path)
      return absent if frontmatter == :absent
      return invalid("#{path} has malformed YAML frontmatter") if frontmatter == :invalid
      if Hive::Dependencies.duplicate_top_level_key?(frontmatter, "depends_on")
        return invalid("#{path} frontmatter contains duplicate depends_on declarations")
      end

      data = YAML.safe_load(
        frontmatter,
        permitted_classes: [ Time, Date ],
        aliases: false
      ) || {}
      return invalid("#{path} frontmatter must contain a mapping") unless data.is_a?(Hash)

      dependency = nil
      if data.key?("depends_on") || data.key?(:depends_on)
        value = data.key?("depends_on") ? data["depends_on"] : data[:depends_on]
        dependency = Hive::Dependencies.parse_declaration(value)
      end

      Result.new(status: :ok, data: data, depends_on: dependency, error: nil)
    rescue Errno::ENOENT
      absent
    rescue Hive::Dependencies::InvalidReference => e
      invalid("#{path} frontmatter depends_on is invalid: #{e.message}")
    rescue Psych::Exception, SystemCallError, IOError => e
      invalid("#{path} frontmatter is unreadable: #{e.class}: #{e.message}")
    end

    def absent
      Result.new(status: :absent, data: {}, depends_on: nil, error: nil)
    end

    def invalid(message)
      Result.new(status: :invalid, data: {}, depends_on: nil, error: message)
    end

    def read_frontmatter(path)
      File.open(path, "rb") do |file|
        opening = file.gets
        return :absent unless opening&.start_with?("---")
        return :invalid unless opening.match?(/\A---[ \t]*(?:\r?\n|\z)/)

        yaml = +""
        while (line = file.gets)
          return yaml if line.match?(/\A---[ \t]*(?:\r?\n|\z)/)
          return :invalid if yaml.bytesize + line.bytesize > MAX_FRONTMATTER_BYTES

          yaml << line
        end
        :invalid
      end
    end
  end
end
