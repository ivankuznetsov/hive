require "digest"
require "json"
require "pathname"
require "rubygems/version"
require "yaml"

module Hive
  module AgentSkills
    # Loads the gem-packaged Hive operating policy and renders deterministic
    # platform wrappers. The canonical digest covers policy and rendered
    # references, never the platform-specific frontmatter or provenance file.
    class CanonicalSkill
      SUPPORTED_SCHEMA_VERSION = 1
      NAME = "hive"
      METADATA_KEYS = %w[$schema schema schema_version name version references].freeze
      FRONTMATTER_KEYS = %w[name description].freeze
      PLATFORM_CONFIG = {
        "openclaw" => { invocation: "/hive", destination_relative: "skills/hive" },
        "claude" => { invocation: "/hive", destination_relative: "skills/hive" },
        "codex" => { invocation: "/hive", destination_relative: "skills/hive" },
        "pi" => { invocation: "/skill:hive", destination_relative: "skills/hive" }
      }.freeze

      class ValidationError < Hive::ConfigError; end

      Projection = Data.define(
        :platform, :invocation, :destination_relative, :skill_version,
        :canonical_digest, :files
      ) do
        def to_h
          {
            "platform" => platform,
            "invocation" => invocation,
            "destination_relative" => destination_relative,
            "skill_version" => skill_version,
            "canonical_digest" => canonical_digest,
            "files" => files.keys.sort
          }
        end
      end

      attr_reader :root, :hive_version

      def self.default_root
        File.expand_path("../../../skills/hive", __dir__)
      end

      def initialize(root: self.class.default_root, hive_version: Hive::VERSION)
        @root = File.expand_path(root)
        @hive_version = hive_version.to_s
      end

      def metadata
        document = JSON.parse(read_source("skill.json"))
        unless document.is_a?(Hash) && document.keys.sort == METADATA_KEYS.sort
          invalid!("skill.json must contain exactly #{METADATA_KEYS.join(', ')}")
        end
        unless document["schema"] == "hive-canonical-skill" &&
               document["schema_version"] == SUPPORTED_SCHEMA_VERSION && document["name"] == NAME
          invalid!("skill.json identity or schema version is invalid")
        end
        unless document["references"].is_a?(Array) && document["references"].uniq == document["references"]
          invalid!("skill.json references must be a unique array")
        end
        begin
          Gem::Version.new(document.fetch("version"))
        rescue ArgumentError
          invalid!("skill.json version must be semantic")
        end

        document.freeze
      rescue JSON::ParserError, KeyError => e
        invalid!("skill.json is invalid: #{e.message}")
      end

      def name = metadata.fetch("name")
      def version = metadata.fetch("version")

      def frontmatter
        parse_skill.fetch(:frontmatter)
      end

      def body
        render_template(parse_skill.fetch(:body))
      end

      def description
        frontmatter.fetch("description")
      end

      def reference_paths
        paths = metadata.fetch("references").map do |path|
          safe_reference_path!(path)
        end
        actual = Dir.glob(File.join(root, "references", "*.md")).sort.map do |path|
          Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
        end
        unless actual == paths.sort
          invalid!("declared references do not match canonical files: declared=#{paths.sort.inspect} actual=#{actual.inspect}")
        end

        paths.freeze
      end

      def rendered_canonical_files
        files = { "SKILL.md" => render_template(read_source("SKILL.md")) }
        reference_paths.each { |path| files[path] = render_template(read_source(path)) }
        files.transform_values { |content| normalize(content) }.freeze
      end

      def canonical_digest
        references = reference_paths.to_h do |path|
          [ path, normalize(render_template(read_source(path))) ]
        end
        payload = {
          "schema" => "hive-canonical-skill-payload",
          "schema_version" => 1,
          "name" => name,
          "skill_version" => version,
          "description" => description,
          "body" => normalize(body),
          "references" => references
        }
        Digest::SHA256.hexdigest(JSON.generate(payload))
      end

      def render(platform)
        platform = platform.to_s
        config = PLATFORM_CONFIG[platform]
        invalid!("unsupported projection platform #{platform.inspect}") unless config

        files = {}
        files["SKILL.md"] = projected_skill_markdown(platform, config)
        reference_paths.each do |path|
          files[path] = normalize(render_template(read_source(path)))
        end
        if platform == "codex"
          files["agents/openai.yaml"] = normalize(render_template(read_source("agents/openai.yaml")))
        end
        files[".hive-skill.json"] = projection_manifest(platform, config, files)
        files = files.sort.to_h.transform_values(&:freeze).freeze

        Projection.new(
          platform: platform.freeze,
          invocation: config.fetch(:invocation).freeze,
          destination_relative: config.fetch(:destination_relative).freeze,
          skill_version: version.freeze,
          canonical_digest: canonical_digest.freeze,
          files: files
        ).freeze
      end

      private

      def parse_skill
        text = normalize(read_source("SKILL.md"))
        match = text.match(/\A---\n(?<frontmatter>.*?)\n---\n(?<body>.*)\z/m)
        invalid!("SKILL.md must contain YAML frontmatter") unless match
        data = YAML.safe_load(match[:frontmatter], permitted_classes: [], aliases: false)
        unless data.is_a?(Hash) && data.keys.sort == FRONTMATTER_KEYS.sort
          invalid!("SKILL.md frontmatter must contain only name and description")
        end
        unless data["name"] == NAME && data["description"].is_a?(String) && !data["description"].empty?
          invalid!("SKILL.md frontmatter name or description is invalid")
        end

        { frontmatter: data.freeze, body: match[:body].sub(/\A\n/, "").freeze }
      rescue Psych::Exception => e
        invalid!("SKILL.md frontmatter is invalid: #{e.message}")
      end

      def projected_skill_markdown(platform, config)
        frontmatter_text = platform == "openclaw" ? openclaw_frontmatter : standard_frontmatter
        wrapper = <<~WRAPPER
          <!-- hive-managed: canonical-skill-projection/v1
          platform: #{platform}
          invocation: #{config.fetch(:invocation)}
          skill-version: #{version}
          canonical-digest: #{canonical_digest}
          hive-version: #{hive_version}
          -->

          Invoke this projection as `#{config.fetch(:invocation)}`.

        WRAPPER
        normalize("#{frontmatter_text}#{wrapper}#{body}")
      end

      def standard_frontmatter
        "---\nname: #{NAME}\ndescription: #{JSON.generate(description)}\n---\n"
      end

      def openclaw_frontmatter
        <<~YAML
          ---
          name: #{NAME}
          description: #{JSON.generate(description)}
          version: #{JSON.generate(version)}
          user-invocable: true
          metadata:
            openclaw:
              homepage: "https://github.com/ivankuznetsov/hive"
              always: true
              install:
                - id: homebrew
                  kind: brew
                  formula: ivankuznetsov/hive/hive
                  bins: [hive]
          ---
        YAML
      end

      def projection_manifest(platform, config, files)
        digests = files.keys.sort.to_h do |path|
          [ path, Digest::SHA256.hexdigest(files.fetch(path)) ]
        end
        JSON.pretty_generate(
          "schema" => "hive-managed-skill-projection",
          "schema_version" => 1,
          "owner" => "hive",
          "platform" => platform,
          "invocation" => config.fetch(:invocation),
          "skill_version" => version,
          "canonical_digest" => canonical_digest,
          "hive_version" => hive_version,
          "files" => digests
        ) + "\n"
      end

      def safe_reference_path!(path)
        unless path.is_a?(String) && path.match?(%r{\Areferences/[a-z0-9][a-z0-9-]*\.md\z})
          invalid!("#{path.inspect} is not a safe reference path")
        end
        read_source(path)
        path
      rescue Errno::ENOENT
        invalid!("missing reference #{path.inspect}")
      end

      def read_source(relative)
        candidate = File.join(root, relative)
        root_real = File.realpath(root)
        candidate_real = File.realpath(candidate)
        unless candidate_real.start_with?("#{root_real}/") && File.file?(candidate_real)
          invalid!("source path escapes canonical skill root: #{relative.inspect}")
        end

        File.binread(candidate_real)
      rescue Errno::ENOENT, Errno::EACCES => e
        raise if relative.start_with?("references/")

        invalid!("cannot read #{relative}: #{e.message}")
      end

      def render_template(content)
        rendered = normalize(content).gsub("{{HIVE_VERSION}}", hive_version)
        if rendered.match?(/\{\{[A-Z0-9_]+\}\}/)
          invalid!("canonical skill contains an unknown template variable")
        end

        rendered
      end

      def normalize(content)
        text = content.to_s.dup.force_encoding(Encoding::UTF_8)
        invalid!("canonical skill content is not valid UTF-8") unless text.valid_encoding?

        text.gsub("\r\n", "\n").sub(/\n*\z/, "\n")
      end

      def invalid!(message)
        raise ValidationError, "canonical Hive skill: #{message}"
      end
    end
  end
end
