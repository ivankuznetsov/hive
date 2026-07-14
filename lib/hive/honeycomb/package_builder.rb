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
      Entry = Data.define(:source, :real_source, :target, :role)
      REQUIRED_METADATA = %w[version author description minimum_hive_version].freeze

      def self.build(**kwargs)
        new(**kwargs).build
      end

      def initialize(workflow:, descriptor_path:, output_dir: nil, version: nil, cfg: {})
        @workflow = workflow
        @descriptor_path = File.expand_path(descriptor_path)
        @owns_staging_root = output_dir.nil?
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
        # The collision guard runs BEFORE the cleanup-protected region: a
        # pre-existing package_root is caller-owned (a supplied output_dir the
        # builder must not touch), so its rejection must not enter the rescue
        # that removes builder-created paths.
        raise Hive::ConfigError, "honeycomb package already exists at #{@package_root}" if File.exist?(@package_root)

        begin
          build_package
        rescue StandardError
          # Remove only what this builder created: the whole staging root when
          # the builder minted it (no caller output_dir), otherwise just the
          # package subtree so a caller-owned output_dir survives the failure.
          FileUtils.rm_rf(@owns_staging_root ? @staging_root : @package_root)
          raise
        end
      end

      private

      def build_package
        metadata = validated_metadata
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
          readme_source ? read_verified_source(readme_source) : generated_readme(metadata, dependencies, permissions)
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
          owns_staging_root: @owns_staging_root,
          id: @workflow.id.to_s,
          version: @selected_version,
          metadata: metadata_hash,
          owners: freeze_owners,
          dependencies: dependencies,
          permission_summary: permissions,
          manifest: manifest
        )
      end

      def validated_metadata
        metadata = @workflow.metadata
        raise Hive::ConfigError, "workflow #{@workflow.id} requires metadata to publish" unless metadata

        missing = REQUIRED_METADATA.reject do |field|
          value = field == "version" ? @selected_version : metadata.public_send(field)
          !value.nil? && !value.to_s.strip.empty?
        end
        unless missing.empty?
          raise Hive::ConfigError,
                "workflow #{@workflow.id} metadata is incomplete for publication: missing #{missing.join(', ')}"
        end
        unless Hive::Workflows::DescriptorParser::SEMVER.match?(@selected_version.to_s)
          raise Hive::ConfigError, "workflow #{@workflow.id} version #{@selected_version.inspect} must be a strict semantic version"
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
          role: role
        )
        @entries[target] = entry
        @source_targets[entry.source] = target
        @owners[target] << context if context
      end

      # The canonical, symlink-safe realpath of the owned workflow directory.
      # Anchoring containment to `realpath(<id>)` alone is insufficient: if the
      # whole `<id>` directory is itself a symlink pointing outside the
      # project's workflows directory, every per-file `start_with?` check still
      # passes and arbitrary external files package cleanly. Require the owned
      # root to be a real directory whose resolved path sits directly inside
      # the resolved descriptor directory, rejecting an escaping root once for
      # both validation-time and read-time resolution.
      def resolved_owned_root
        @resolved_owned_root ||= begin
          real_parent = File.realpath(File.dirname(@descriptor_path))
          expected = File.join(real_parent, File.basename(@owned_root))
          real_owned = File.realpath(@owned_root)
          unless File.directory?(real_owned) && real_owned == expected
            raise Hive::ConfigError,
                  "owned workflow directory #{@owned_root.inspect} resolves outside #{real_parent}"
          end
          real_owned
        end
      end

      def validate_owned_file(source, label:, with_target: false, allow_reserved: false)
        logical_root = File.expand_path(@owned_root)
        logical_source = File.expand_path(source)
        relative = Pathname.new(logical_source).relative_path_from(Pathname.new(logical_root)).cleanpath.to_s
        if relative == ".." || relative.start_with?("../")
          raise Hive::ConfigError,
                "#{label} #{source.inspect} is outside owned workflow directory #{logical_root}"
        end

        real_root = resolved_owned_root
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
          File.binwrite(destination, read_verified_source(entry.real_source))
        end
      end

      # Reads a source that was validated earlier, re-checking containment at
      # read time. `real_source` was captured via realpath during validation,
      # but the on-disk leaf could be swapped for an outside-pointing symlink
      # between validation and this read (a local TOCTOU race). Re-resolving and
      # opening with O_NOFOLLOW closes that window so package contents can only
      # ever come from inside the owned workflow directory.
      def read_verified_source(real_source)
        real_root = resolved_owned_root
        resolved = File.realpath(real_source)
        unless resolved == real_root || resolved.start_with?("#{real_root}#{File::SEPARATOR}")
          raise Hive::ConfigError,
                "packaged source #{real_source.inspect} resolves outside owned workflow directory at read time"
        end
        File.open(real_source, File::RDONLY | File::NOFOLLOW) do |io|
          raise Hive::ConfigError, "packaged source #{real_source.inspect} is no longer a regular file" unless io.stat.file?

          io.binmode
          io.read
        end
      rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP => e
        raise Hive::ConfigError, "packaged source #{real_source.inspect} cannot be read for packaging: #{e.message}"
      end

      def descriptor_bytes(metadata)
        raw = consistent_descriptor_snapshot
        raw.fetch("metadata")["version"] = @selected_version
        raw.fetch("metadata")["readme"] = "./README.md" if metadata.readme
        # Emit `assets:` only when the source declared assets, mirroring the
        # readme guard above: an empty list must not synthesize a spurious
        # `assets: []` key that the source descriptor never carried.
        unless metadata.assets.empty?
          raw.fetch("metadata")["assets"] = metadata.assets.map do |asset|
            "./#{@source_targets.fetch(File.expand_path(asset))}"
          end
        end
        raw.fetch("stages").each do |stage|
          rewrite_instruction(stage)
          Array(stage["reviewers"]).each { |reviewer| rewrite_instruction(reviewer) }
          rewrite_instruction(stage.dig("council", "revise")) if stage.dig("council", "revise")
        end
        YAML.dump(raw)
      rescue Psych::Exception, SystemCallError, IOError, KeyError => e
        raise Hive::ConfigError, "workflow descriptor #{@descriptor_path} could not be packaged: #{e.message}"
      end

      # Reads the descriptor exactly once and re-validates that this snapshot
      # still parses to the same workflow model preflight and the manifest were
      # built from. The model is parsed by the caller and the raw YAML is
      # re-read here; without this check a concurrent edit between those two
      # reads could slip different permissions or skills into the packaged
      # workflow.yml while the trusted model stayed stale. On divergence, fail
      # closed rather than package bytes that were never validated.
      def consistent_descriptor_snapshot
        data = YAML.safe_load(File.read(@descriptor_path))
        reparsed = Hive::Workflows::DescriptorParser.parse_hash(data, path: @descriptor_path)
        unless reparsed == @workflow
          raise Hive::ConfigError,
                "workflow descriptor #{@descriptor_path} changed during packaging; re-run the publish"
        end
        data
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
        Hive::Honeycomb.sort_dependencies(rows).freeze
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
