require "fileutils"
require "pathname"
require "tmpdir"
require "yaml"
require "hive/honeycomb"
require "hive/honeycomb/manifest"
require "hive/honeycomb/permission_summary"
require "hive/workflows/descriptor_parser"

module Hive
  module Honeycomb
    class PackageBuilder
      Entry = Data.define(:source, :real_source, :target, :owners, :role)
      REQUIRED_METADATA = %w[version author description minimum_hive_version].freeze

      def self.build(**kwargs)
        new(**kwargs).build
      end

      def initialize(workflow:, descriptor_path:, output_dir: nil, version: nil, cfg: {})
        @workflow = workflow
        @descriptor_path = File.expand_path(descriptor_path)
        @staging_root = output_dir ? File.expand_path(output_dir) : Dir.mktmpdir("hive-honeycomb")
        @package_root = File.join(@staging_root, "workflows", workflow.id.to_s)
        @owned_root = File.join(File.dirname(@descriptor_path), workflow.id.to_s)
        @selected_version = version || workflow.metadata&.version
        @cfg = cfg || {}
        @entries = {}
        @source_targets = {}
        @owners = Hash.new { |hash, key| hash[key] = [] }
      end

      def build
        metadata = validated_metadata
        raise Hive::ConfigError, "honeycomb package already exists at #{@package_root}" if File.exist?(@package_root)

        collect_instruction_files
        collect_assets(metadata)
        readme_source = metadata.readme && validate_owned_file(
          metadata.readme,
          label: "metadata readme",
          allow_reserved: true
        )
        FileUtils.mkdir_p(@package_root)
        write_collected_files
        dependencies = collect_dependencies
        permissions = PermissionSummary.build(@workflow)
        File.binwrite(File.join(@package_root, "workflow.yml"), descriptor_bytes(metadata))
        File.binwrite(
          File.join(@package_root, "README.md"),
          readme_source ? File.binread(readme_source) : generated_readme(metadata, dependencies, permissions)
        )
        metadata_hash = portable_metadata(metadata)
        manifest = Manifest.write(
          package_root: @package_root,
          id: @workflow.id,
          metadata: metadata_hash,
          dependencies: dependencies,
          permission_summary: permissions,
          review_required: []
        )
        Package.new(
          staging_root: @staging_root,
          package_root: @package_root,
          id: @workflow.id.to_s,
          version: @selected_version,
          metadata: metadata_hash,
          owners: freeze_owners,
          dependencies: dependencies,
          permission_summary: permissions,
          manifest: manifest
        )
      rescue StandardError
        FileUtils.rm_rf(@package_root)
        raise
      end

      private

      def validated_metadata
        metadata = @workflow.metadata
        raise Hive::ConfigError, "workflow #{@workflow.id} requires metadata to publish" unless metadata

        unless Hive::Workflows::DescriptorParser::SEMVER.match?(@selected_version.to_s)
          raise Hive::ConfigError, "workflow #{@workflow.id} version #{@selected_version.inspect} must be a strict semantic version"
        end
        missing = REQUIRED_METADATA.reject do |field|
          value = field == "version" ? @selected_version : metadata.public_send(field)
          !value.nil? && !value.to_s.strip.empty?
        end
        unless missing.empty?
          raise Hive::ConfigError,
                "workflow #{@workflow.id} metadata is incomplete for publication: missing #{missing.join(', ')}"
        end

        metadata.with(version: @selected_version)
      end

      def collect_instruction_files
        @workflow.stages.each do |stage|
          add_file(stage.instruction, context: "stage:#{stage.name}", role: :instruction) if stage.instruction
          next unless stage.kind == :council

          Array(stage.reviewers).each do |reviewer|
            next unless reviewer.instruction

            add_file(
              reviewer.instruction,
              context: "stage:#{stage.name}/reviewer:#{reviewer.name}",
              role: :instruction
            )
          end
          revise = stage.council&.revise
          if revise&.instruction
            add_file(revise.instruction, context: "stage:#{stage.name}/revise", role: :instruction)
          end
        end
      end

      def collect_assets(metadata)
        metadata.assets.each { |asset| add_file(asset, context: nil, role: :asset) }
      end

      def add_file(source, context:, role:)
        real_source, target = validate_owned_file(source, label: role.to_s, with_target: true)
        existing = @entries[target]
        if existing
          if role == :instruction && existing.role == :instruction && existing.source == File.expand_path(source)
            @owners[target] << context if context
            return
          end
          raise Hive::ConfigError, "duplicate packaged path #{target.inspect}"
        end

        entry = Entry.new(
          source: File.expand_path(source),
          real_source: real_source,
          target: target,
          owners: context ? [ context ].freeze : [].freeze,
          role: role
        )
        @entries[target] = entry
        @source_targets[entry.source] = target
        @owners[target] << context if context
      end

      def validate_owned_file(source, label:, with_target: false, allow_reserved: false)
        logical_root = File.expand_path(@owned_root)
        logical_source = File.expand_path(source)
        relative = Pathname.new(logical_source).relative_path_from(Pathname.new(logical_root)).cleanpath.to_s
        if relative == ".." || relative.start_with?("../")
          raise Hive::ConfigError,
                "#{label} #{source.inspect} is outside owned workflow directory #{logical_root}"
        end

        real_root = File.realpath(logical_root)
        real_source = File.realpath(logical_source)
        unless real_source.start_with?("#{real_root}#{File::SEPARATOR}")
          raise Hive::ConfigError,
                "#{label} #{source.inspect} resolves outside owned workflow directory #{logical_root}"
        end
        unless File.file?(real_source) && File.readable?(real_source)
          raise Hive::ConfigError, "#{label} #{source.inspect} must be a readable regular file"
        end

        target = relative.tr(File::SEPARATOR, "/")
        if !allow_reserved && RESERVED_PATHS.include?(target)
          raise Hive::ConfigError, "#{label} #{source.inspect} claims reserved output name #{target}"
        end
        with_target ? [ real_source, target ] : real_source
      rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP => e
        raise Hive::ConfigError, "#{label} #{source.inspect} cannot be packaged: #{e.message}"
      end

      def write_collected_files
        @entries.values.sort_by(&:target).each do |entry|
          destination = File.join(@package_root, entry.target)
          FileUtils.mkdir_p(File.dirname(destination))
          File.binwrite(destination, File.binread(entry.real_source))
        end
      end

      def descriptor_bytes(metadata)
        raw = YAML.safe_load(File.read(@descriptor_path))
        raw.fetch("metadata")["version"] = @selected_version
        raw.fetch("metadata")["readme"] = "./README.md" if metadata.readme
        raw.fetch("metadata")["assets"] = metadata.assets.map do |asset|
          "./#{@source_targets.fetch(File.expand_path(asset))}"
        end
        raw.fetch("stages").each do |stage|
          rewrite_instruction(stage)
          Array(stage["reviewers"]).each { |reviewer| rewrite_instruction(reviewer) }
          rewrite_instruction(stage.dig("council", "revise")) if stage.dig("council", "revise")
        end
        YAML.dump(raw)
      rescue Psych::Exception, SystemCallError, IOError => e
        raise Hive::ConfigError, "workflow descriptor #{@descriptor_path} could not be packaged: #{e.message}"
      end

      def rewrite_instruction(container)
        return unless container&.key?("instruction") && container["instruction"]

        source = File.expand_path(container.fetch("instruction"), File.dirname(@descriptor_path))
        container["instruction"] = "./#{@source_targets.fetch(source)}"
      end

      def collect_dependencies
        rows = []
        @workflow.stages.each do |stage|
          agent = context_agent(stage)
          rows << dependency(stage.skill, "stage:#{stage.name}", agent) if stage.skill
          next unless stage.kind == :council

          Array(stage.reviewers).each do |reviewer|
            next unless reviewer.skill

            rows << dependency(
              reviewer.skill,
              "stage:#{stage.name}/reviewer:#{reviewer.name}",
              context_agent(stage, reviewer.agent)
            )
          end
          revise = stage.council&.revise
          if revise&.skill
            rows << dependency(
              revise.skill,
              "stage:#{stage.name}/revise",
              context_agent(stage, revise.agent)
            )
          end
        end
        rows.sort_by { |row| [ row.fetch("context"), row.fetch("skill") ] }.freeze
      end

      def dependency(skill, context, agent)
        { "skill" => skill, "context" => context, "agent" => agent, "required" => true }.freeze
      end

      def context_agent(stage, context_agent = nil)
        (context_agent || stage.agent || @cfg.dig(stage.name, "agent") || "claude").to_s
      end

      def generated_readme(metadata, dependencies, permissions)
        lines = [
          "# #{@workflow.id}",
          "",
          metadata.description,
          "",
          "- Version: #{@selected_version}",
          "- Author: #{metadata.author}",
          "- Minimum Hive version: #{metadata.minimum_hive_version}",
          "",
          "## External dependencies",
          ""
        ]
        if dependencies.empty?
          lines << "None."
        else
          dependencies.each do |row|
            lines << "- `#{row.fetch('skill')}` via #{row.fetch('agent')} (#{row.fetch('context')})"
          end
        end
        lines.concat([ "", "## Permissions and shell exposure", "" ])
        permissions.fetch("contexts").each do |row|
          line = "- #{row.fetch('context')}: #{row.fetch('preset')}; shell=#{row.fetch('shell_exposure')}"
          justification = row["shell_justification"]
          line = "#{line}; justification=#{justification}" if justification
          lines << line
        end
        "#{lines.join("\n")}\n"
      end

      def portable_metadata(metadata)
        {
          "version" => @selected_version,
          "author" => metadata.author,
          "description" => metadata.description,
          "minimum_hive_version" => metadata.minimum_hive_version
        }.freeze
      end

      def freeze_owners
        @owners.to_h do |path, contexts|
          [ path, contexts.compact.uniq.sort.freeze ]
        end.freeze
      end
    end
  end
end
