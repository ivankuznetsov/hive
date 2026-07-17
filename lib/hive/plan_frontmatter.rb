require "date"
require "yaml"
require "hive/dependencies"

module Hive
  module PlanFrontmatter
    MAX_FRONTMATTER_BYTES = 65_536

    Result = Data.define(:status, :data, :depends_on, :error) do
      def depends_on_present?
        !depends_on.nil?
      end

      def valid?
        %i[ok absent].include?(status)
      end
    end

    module_function

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
        dependency = Hive::Dependencies.parse_reference(value)
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
