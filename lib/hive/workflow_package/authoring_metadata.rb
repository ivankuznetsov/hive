require "psych"
require "rubygems"
require "uri"
require "hive/workflow_package/registry_manifest"

module Hive
  module WorkflowPackage
    class AuthoringMetadata < Data.define(
      :description, :author, :license, :hive_min_version, :source, :assets
    )
      FILE_NAME = "honeycomb.yml".freeze
      KEYS = %w[description author license hive_min_version source assets].freeze
      REQUIRED_KEYS = (KEYS - [ "assets" ]).freeze
      README_SECTIONS = [
        "Behavior", "Prerequisites", "Inputs", "Outputs", "Permissions and Risks", "Recovery"
      ].freeze
      PLACEHOLDER = /(?:\b(?:todo|tbd|replace(?:\s+me)?|your\s+name|example\s+only)\b|<[^>]+>|\A\s*describe\b)/i
      MAX_BYTES = 256 * 1024

      class << self
        def load(path)
          bytes = bounded_read(path, label: FILE_NAME)
          data = parse_yaml_map(bytes, label: FILE_NAME)
          validate_keys!(data)

          description = required_text(data["description"], "description")
          author = validate_author!(data["author"])
          license = required_text(data["license"], "license")
          unless Gem::Licenses.match?(license) && !license.match?(/\s(?:AND|OR|WITH)\s/)
            fail_field!("license", "must be one SPDX license identifier")
          end
          hive_min_version = required_text(data["hive_min_version"], "hive_min_version")
          unless RegistryManifest::SEMVER.match?(hive_min_version)
            fail_field!("hive_min_version", "must be strict SemVer")
          end
          source = validate_source!(data["source"])
          assets = validate_assets!(data.fetch("assets", []))
          [ description, author["name"], author["url"], source["url"] ].each_with_index do |value, index|
            fail_field!(%w[description author.name author.url source.url][index], "contains an authoring placeholder") if placeholder?(value)
          end

          new(
            description: description, author: author.freeze, license: license,
            hive_min_version: hive_min_version, source: source.freeze, assets: assets.freeze
          ).freeze
        rescue Errno::ENOENT, Errno::EACCES, IOError
          raise Hive::ConfigError, "workflow publish requires a readable #{FILE_NAME}"
        end

        def validate_readme!(bytes, path: "README.md")
          text = utf8(bytes, label: path)
          headings = []
          text.each_line.with_index do |line, index|
            match = /\A##\s+(.+?)\s*\z/.match(line)
            headings << [ match[1], index ] if match
          end
          lines = text.lines
          README_SECTIONS.each do |section|
            matches = headings.each_index.select { |index| headings[index][0] == section }
            fail_readme!(section, "must appear exactly once") unless matches.length == 1

            heading_index = matches.first
            start_line = headings[heading_index][1] + 1
            end_line = headings[heading_index + 1]&.at(1) || lines.length
            content = lines[start_line...end_line].join.strip
            if content.empty? || placeholder?(content) || content.gsub(/[-*#_`\s]/, "").empty?
              fail_readme!(section, "must contain authored non-placeholder content")
            end
          end
          true
        end

        # Safe YAML boundary shared with SourceSnapshot. It rejects duplicate
        # keys before Psych's normal Hash projection could silently keep one.
        def parse_yaml_map(bytes, label:)
          text = utf8(bytes, label: label)
          stream = Psych.parse_stream(text)
          unless stream.children.length == 1 && stream.children.first&.root
            raise Hive::ConfigError, "#{label} must contain exactly one YAML document"
          end
          reject_duplicate_keys!(stream.children.first.root, label: label)
          value = Psych.safe_load(text, permitted_classes: [], permitted_symbols: [], aliases: false)
          raise Hive::ConfigError, "#{label} must contain a map" unless value.is_a?(Hash)
          unless value.keys.all? { |key| key.is_a?(String) }
            raise Hive::ConfigError, "#{label} keys must be strings"
          end

          value
        rescue Psych::Exception
          raise Hive::ConfigError, "#{label} is not safe YAML"
        end

        private

        def validate_keys!(data)
          missing = REQUIRED_KEYS - data.keys
          unknown = data.keys - KEYS
          fail_field!(missing.first, "is required") unless missing.empty?
          fail_field!(unknown.first, "is not owned by #{FILE_NAME}") unless unknown.empty?
        end

        def validate_author!(value)
          unless value.is_a?(Hash) && value.keys.sort == %w[name url]
            fail_field!("author", "must contain only name and url")
          end
          {
            "name" => required_text(value["name"], "author.name"),
            "url" => validate_url!(value["url"], "author.url")
          }
        end

        def validate_source!(value)
          unless value.is_a?(Hash) && value.keys.sort == %w[revision url]
            fail_field!("source", "must contain only url and revision")
          end
          revision = required_text(value["revision"], "source.revision")
          unless RegistryManifest::REVISION.match?(revision)
            fail_field!("source.revision", "must be a lowercase immutable 40- or 64-hex revision")
          end
          { "url" => validate_url!(value["url"], "source.url"), "revision" => revision }
        end

        def validate_assets!(value)
          fail_field!("assets", "must be an array") unless value.is_a?(Array)
          paths = value.map.with_index do |path, index|
            fail_field!("assets[#{index}]", "must be a non-empty string") unless path.is_a?(String) && !path.empty?
            normalized = path.unicode_normalize(:nfc)
            RegistryManifest.validate_relative_path!(normalized)
            normalized
          rescue PackageError
            fail_field!("assets[#{index}]", "must be a normalized relative path")
          end
          fail_field!("assets", "must be sorted and unique after Unicode normalization") unless paths.sort.uniq == paths
          paths
        end

        def validate_url!(value, field)
          text = required_text(value, field)
          uri = URI.parse(text)
          unless %w[http https].include?(uri.scheme) && uri.host && !uri.host.empty? &&
                 uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
            fail_field!(field, "must be an absolute credential-free HTTP(S) URL")
          end
          text
        rescue URI::InvalidURIError
          fail_field!(field, "must be an absolute credential-free HTTP(S) URL")
        end

        def required_text(value, field)
          fail_field!(field, "must be a non-empty string") unless value.is_a?(String) && !value.strip.empty?
          value
        end

        def bounded_read(path, label:)
          stat = File.lstat(path)
          unless stat.file? && !stat.symlink? && stat.size <= MAX_BYTES
            raise Hive::ConfigError, "#{label} must be a bounded regular file"
          end
          File.binread(path)
        end

        def utf8(bytes, label:)
          text = bytes.to_s.dup.force_encoding(Encoding::UTF_8)
          raise Hive::ConfigError, "#{label} must be valid UTF-8" unless text.valid_encoding?
          text
        end

        def reject_duplicate_keys!(node, label:)
          case node
          when Psych::Nodes::Mapping
            seen = {}
            node.children.each_slice(2) do |key, value|
              unless key.is_a?(Psych::Nodes::Scalar)
                raise Hive::ConfigError, "#{label} keys must be scalar strings"
              end
              raise Hive::ConfigError, "#{label} contains a duplicate key" if seen[key.value]
              seen[key.value] = true
              reject_duplicate_keys!(value, label: label)
            end
          else
            Array(node.respond_to?(:children) ? node.children : []).each do |child|
              reject_duplicate_keys!(child, label: label)
            end
          end
        end

        def placeholder?(value) = PLACEHOLDER.match?(value.to_s.strip)

        def fail_field!(field, message)
          raise Hive::ConfigError, "#{FILE_NAME} #{field} #{message}"
        end

        def fail_readme!(section, message)
          raise Hive::ConfigError, "README.md section #{section.inspect} #{message}"
        end
      end
    end
  end
end
