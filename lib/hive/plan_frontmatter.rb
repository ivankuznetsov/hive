require "date"
require "digest"
require "psych"
require "stringio"
require "yaml"
require "hive/dependencies"

module Hive
  module PlanFrontmatter
    MAX_FRONTMATTER_BYTES = 65_536
    EMPTY_ISSUES = [].freeze
    EMPTY_ENTRIES = [].freeze

    Result = Data.define(
      :status, :data, :depends_on, :error,
      :has_depends_on, :raw_depends_on, :issues, :invalid_kind, :entries
    ) do
      def initialize(status:, data: {}, depends_on: nil, error: nil,
                     has_depends_on: false, raw_depends_on: nil,
                     issues: EMPTY_ISSUES, invalid_kind: nil, entries: EMPTY_ENTRIES)
        super
      end

      def valid?
        %i[ok absent].include?(status)
      end

      def has_depends_on?
        has_depends_on == true
      end
    end

    module_function

    def read(path)
      frontmatter = read_frontmatter(path)
      parse_frontmatter_result(frontmatter, label: path)
    rescue Errno::ENOENT
      absent
    rescue SystemCallError, IOError => e
      message = "#{path} frontmatter is unreadable: #{e.class}: #{e.message}"
      invalid(
        message,
        invalid_kind: :unreadable,
        issues: [ Hive::Dependencies::DeclarationIssue.new(
          index: nil, raw_value: nil, display_value: path.to_s,
          code: :unreadable_frontmatter, message: message
        ) ]
      )
    end

    def parse(content, label: "plan.md")
      frontmatter = read_frontmatter_from_io(StringIO.new(content.to_s))
      parse_frontmatter_result(frontmatter, label: label)
    end

    def file_digest(path)
      stat = File.lstat(path)
      return :invalid if stat.symlink? || !stat.file?

      Digest::SHA256.file(path).hexdigest
    rescue Errno::ENOENT
      nil
    rescue SystemCallError, IOError
      :invalid
    end

    def absent
      Result.new(status: :absent, data: {}, depends_on: nil, error: nil)
    end

    def invalid(message, data: {}, has_depends_on: false, raw_depends_on: nil,
                issues: EMPTY_ISSUES, invalid_kind: :malformed_frontmatter,
                entries: EMPTY_ENTRIES)
      Result.new(
        status: :invalid,
        data: data,
        depends_on: nil,
        error: message,
        has_depends_on: has_depends_on,
        raw_depends_on: Hive::Dependencies.json_safe_value(raw_depends_on),
        issues: Array(issues).freeze,
        invalid_kind: invalid_kind,
        entries: Array(entries).freeze
      )
    end

    def parse_frontmatter_result(frontmatter, label:)
      return absent if frontmatter == :absent
      if frontmatter == :oversized
        message = "#{label} has malformed YAML frontmatter (exceeds #{MAX_FRONTMATTER_BYTES} bytes)"
        return invalid(
          message,
          invalid_kind: :oversized_frontmatter,
          issues: [ Hive::Dependencies::DeclarationIssue.new(
            index: nil, raw_value: nil, display_value: "frontmatter",
            code: :oversized_frontmatter, message: message
          ) ]
        )
      end
      if frontmatter == :invalid
        message = "#{label} has malformed YAML frontmatter"
        return invalid(
          message,
          invalid_kind: :malformed_frontmatter,
          issues: [ Hive::Dependencies::DeclarationIssue.new(
            index: nil, raw_value: nil, display_value: "frontmatter",
            code: :malformed_frontmatter, message: message
          ) ]
        )
      end
      if Hive::Dependencies.duplicate_top_level_key?(frontmatter, "depends_on")
        duplicates = extract_duplicate_key_values(frontmatter, "depends_on")
        message = "#{label} frontmatter contains duplicate depends_on declarations"
        issues = if duplicates.empty?
          [ Hive::Dependencies::DeclarationIssue.new(
            index: nil, raw_value: nil, display_value: "depends_on",
            code: :duplicate_depends_on, message: message
          ) ]
        else
          duplicates.each_with_index.map do |value, index|
            Hive::Dependencies::DeclarationIssue.new(
              index: index, raw_value: value,
              code: :duplicate_depends_on, message: message
            )
          end
        end
        return invalid(
          message,
          has_depends_on: true,
          raw_depends_on: duplicates,
          issues: issues,
          invalid_kind: :duplicate_depends_on
        )
      end

      data = YAML.safe_load(
        frontmatter,
        permitted_classes: [ Time, Date ],
        aliases: false
      ) || {}
      unless data.is_a?(Hash)
        message = "#{label} frontmatter must contain a mapping"
        return invalid(
          message,
          raw_depends_on: data,
          invalid_kind: :non_mapping,
          issues: [ Hive::Dependencies::DeclarationIssue.new(
            index: nil, raw_value: data,
            code: :non_mapping, message: message
          ) ]
        )
      end

      has_depends_on = data.key?("depends_on") || data.key?(:depends_on)
      unless has_depends_on
        return Result.new(status: :ok, data: data, depends_on: nil, error: nil)
      end

      raw_value = data.key?("depends_on") ? data["depends_on"] : data[:depends_on]
      inspection = Hive::Dependencies.inspect_declaration(raw_value)
      if inspection.valid?
        return Result.new(
          status: :ok,
          data: data,
          depends_on: inspection.parsed,
          error: nil,
          has_depends_on: true,
          raw_depends_on: inspection.raw_value,
          issues: EMPTY_ISSUES,
          invalid_kind: nil,
          entries: inspection.entries
        )
      end

      invalid(
        "#{label} frontmatter depends_on is invalid: #{inspection.summary_message}",
        data: data,
        has_depends_on: true,
        raw_depends_on: inspection.raw_value,
        issues: inspection.issues,
        invalid_kind: :invalid_depends_on,
        entries: inspection.entries
      )
    rescue Psych::Exception => e
      message = "#{label} frontmatter is unreadable: #{e.class}: #{e.message}"
      invalid(
        message,
        invalid_kind: :malformed_yaml,
        issues: [ Hive::Dependencies::DeclarationIssue.new(
          index: nil, raw_value: nil, display_value: "frontmatter",
          code: :malformed_yaml, message: message
        ) ]
      )
    end

    def extract_duplicate_key_values(yaml, key)
      mapping = Psych.parse(yaml)&.root
      return [] unless mapping.is_a?(Psych::Nodes::Mapping)

      values = []
      mapping.children.each_slice(2) do |key_node, value_node|
        next unless key_node.is_a?(Psych::Nodes::Scalar) && key_node.value == key

        values << safe_psych_node(value_node)
      end
      values
    rescue Psych::Exception
      []
    end

    def safe_psych_node(node)
      case node
      when Psych::Nodes::Scalar
        node.value
      when Psych::Nodes::Sequence
        node.children.map { |child| safe_psych_node(child) }
      when Psych::Nodes::Mapping
        node.children.each_slice(2).with_object({}) do |(k, v), hash|
          hash[safe_psych_node(k).to_s] = safe_psych_node(v)
        end
      else
        nil
      end
    end

    def read_frontmatter(path)
      File.open(path, "rb") { |file| read_frontmatter_from_io(file) }
    end

    def read_frontmatter_from_io(io)
      opening = io.gets
      return :absent unless opening&.start_with?("---")
      return :invalid unless opening.match?(/\A---[ \t]*(?:\r?\n|\z)/)

      yaml = +""
      while (line = io.gets)
        return yaml if line.match?(/\A---[ \t]*(?:\r?\n|\z)/)
        return :oversized if yaml.bytesize + line.bytesize > MAX_FRONTMATTER_BYTES

        yaml << line
      end
      :invalid
    end
  end
end
