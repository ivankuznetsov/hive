require "date"
require "yaml"
require "hive/dependencies"

module Hive
  module PlanFrontmatter
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
      text = File.read(path)
      return absent unless text.start_with?("---")

      match = text.match(/\A---[ \t]*\r?\n(.*?)\r?\n---[ \t]*(?:\r?\n|\z)/m)
      return invalid("#{path} has malformed YAML frontmatter") unless match

      data = YAML.safe_load(
        match[1],
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
  end
end
