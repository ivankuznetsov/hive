require "json"
require "open3"
require "pathname"
require "set"
require "hive/patrol/architecture_mapper"
require "hive/patrol/feature"
require "hive/patrol/source_reader"
require "hive/patrol/state_store"

module Hive
  module Patrol
    class Mapper
      DEFAULT_EXCLUDES = [ ".git", ".hive-state" ].freeze
      DOCUMENTATION_EXTENSIONS = %w[.md .mdx .rst .adoc .asciidoc].freeze
      DOCUMENTATION_ROOT_NAMES = %w[
        README CONTRIBUTING ARCHITECTURE DESIGN DECISIONS CONCEPTS SECURITY SUPPORT
      ].freeze
      DOCUMENTATION_EXCLUDES = [
        %r{\Awiki/log\.md\z}i,
        %r{\Awiki/log\.d/}i,
        %r{\Araw/notes(?:/|\z)}i,
        %r{(?:\A|/)(?:\.cache|cache|caches)(?:/|\z)}i,
        %r{(?:\A|/)\.hive-state(?:/|\z)}i
      ].freeze

      def initialize(project_root, cfg:, state: StateStore.new(project_root), dry_run: false,
                     capabilities: [], documentation_changes: [])
        @project_root = File.expand_path(project_root)
        @cfg = cfg
        @state = state
        @dry_run = dry_run
        @capabilities = Array(capabilities).map(&:to_sym)
        @documentation_changes = Array(documentation_changes)
        @source_reader = Hive::Patrol::SourceReader.new(@project_root)
      end

      def call
        # A dry run must not create durable artifacts under the state tree, so
        # skip ensure!/write_feature and only compute the mapping in memory.
        @state.ensure! unless @dry_run
        files = tracked_files
        features = []
        if architecture_capability?
          # Component mapping owns production source and manifests exactly
          # once, attaches subsystem tests, and keeps command entrypoints as
          # their own public-contract slices. Adding the legacy route,
          # package, and monolithic test-suite slices here recreated the same
          # behavior under several feature ids — the main source of patrol's
          # duplicate PR waves.
          commands = command_features(files)
          features.concat(commands)
          features.concat(architecture_features(files, separately_reviewed: commands))
        else
          features.concat(route_features(files))
          features.concat(command_features(files))
          features.concat(package_features(files))
          features.concat(test_features(files))
        end
        if documentation_capability? && (features.empty? || documentation_changes_provided?)
          features.concat(documentation_features(files))
        end
        features = dedupe(features)
        features.each { |feature| @state.write_feature(feature) } unless @dry_run
        features
      end

      private

      def documentation_capability?
        @capabilities.include?(:documentation)
      end

      def architecture_capability?
        @capabilities.include?(:architecture)
      end

      def documentation_changes_provided?
        @documentation_changes.any?
      end

      def documentation_features(files)
        tracked = files.select { |path| documentation_path?(path) }
        tracked_set = tracked.to_set
        changed = documentation_change_paths(tracked_set)
        changed_set = changed.to_set
        candidates = documentation_changes_provided? ? changed : tracked
        tracked_by_group = tracked.group_by { |path| documentation_group(path) }
        root_docs = root_document_paths(tracked)
        candidates.uniq.group_by { |path| documentation_group(path) }.sort.flat_map do |group, paths|
          ordered = paths.sort
          owned_slices = documentation_changes_provided? ? ordered.each_slice(max_owned_files).to_a : [ capped(ordered, max_owned_files) ]
          unchanged_group_docs = Array(tracked_by_group[group]).reject { |path| changed_set.include?(path) }
          context = capped((root_docs + unchanged_group_docs).uniq, max_context_files)

          owned_slices.each_with_index.map do |owned, index|
            id_group = index.zero? ? group : "#{group}/part-#{index + 1}"
            Feature.new(
              id: stable_id("documentation", id_group),
              kind: "documentation",
              entrypoints: [ owned.first ],
              owned_files: owned,
              context_files: context - owned,
              tests: []
            )
          end
        end
      end

      def documentation_path?(path)
        value = path.to_s.tr("\\", "/")
        return false if value.empty? || DOCUMENTATION_EXCLUDES.any? { |pattern| value.match?(pattern) }
        return false unless DOCUMENTATION_EXTENSIONS.include?(File.extname(value).downcase)

        parts = value.split("/")
        return DOCUMENTATION_ROOT_NAMES.include?(File.basename(value, File.extname(value)).upcase) if parts.one?
        return true if %w[docs wiki adr adrs decisions].include?(parts.first.downcase)

        parts.first.casecmp?("architecture") && %w[adr adrs decisions].include?(parts[1].to_s.downcase)
      end

      def documentation_change_paths(tracked)
        @documentation_changes.flat_map do |change|
          next [] unless change.is_a?(Hash)

          paths = []
          current = change["path"].to_s
          if safe_documentation_path?(current) &&
             (tracked.include?(current) || removed_documentation_path?(current, change["status"]))
            paths << current
          end

          previous = change["previous_path"].to_s
          if safe_documentation_path?(previous) &&
             (tracked.include?(previous) || !path_entry_exists?(previous))
            paths << previous
          end
          paths
        end
      end

      def safe_documentation_path?(path)
        return false if path.empty? || path.include?("\\")

        relative = Pathname.new(path)
        !relative.absolute? && relative.cleanpath.to_s == path && path != "." &&
          included?(path) && documentation_path?(path)
      end

      def removed_documentation_path?(path, status)
        status.to_s == "removed" && !path_entry_exists?(path)
      end

      def path_entry_exists?(path)
        File.lstat(File.join(@project_root, path))
        true
      rescue SystemCallError
        false
      end

      def documentation_group(path)
        parts = path.split("/")
        return "root" if parts.one?

        top = parts.first.downcase
        return top if %w[adr adrs decisions].include?(top)
        return "#{top}/#{parts[1].downcase}" if top == "architecture"

        second = parts.length > 2 ? parts[1].downcase : "root"
        "#{top}/#{second}"
      end

      def root_document_paths(paths)
        paths.select { |path| path.split("/").one? }
      end

      def tracked_files
        out, = Open3.capture3("git", "-C", @project_root, "ls-files", "-z")
        files = utf8(out).split("\0").reject(&:empty?)
        files = Dir.glob("**/*", File::FNM_DOTMATCH, base: @project_root).select do |path|
          File.file?(File.join(@project_root, path))
        end if files.empty?

        files.map { |path| utf8(path).tr("\\", "/") }
             .select { |path| included?(path) && @source_reader.regular_file?(path) }
             .sort
      end

      # git emits raw filename bytes; a non-UTF-8 name (for example Latin-1)
      # would raise ArgumentError from split/tr/downcase/regex downstream, so
      # sanitize once at the boundary where the file list enters. A scrubbed
      # name no longer resolves to a real file and is simply not mapped.
      def utf8(value)
        value.to_s.b.force_encoding(Encoding::UTF_8).scrub
      end

      def included?(path)
        return false if path.split("/").any? { |part| DEFAULT_EXCLUDES.include?(part) }

        excludes = Array(@cfg.dig("patrol", "exclude"))
        return false if excludes.any? { |glob| match_glob?(glob, path) }

        includes = Array(@cfg.dig("patrol", "include"))
        includes.empty? || includes.any? { |glob| match_glob?(glob, path) }
      end

      def match_glob?(glob, path)
        glob = glob.to_s.tr("\\", "/")
        File.fnmatch?(glob, path, File::FNM_PATHNAME | File::FNM_EXTGLOB) ||
          path == glob ||
          path.start_with?("#{glob}/")
      end

      def route_features(files)
        features = []
        files.grep(%r{\A(app/(.*/)?page|pages/).*\.(js|jsx|ts|tsx)\z}).each do |path|
          features << build_feature("route", path, files)
        end

        files.grep(/\.py\z/).each do |path|
          content = read(path)
          next unless content.match?(/@(app|router)\.(route|get|post|put|patch|delete)\b/)

          features << build_feature("route", path, files)
        end
        features
      end

      def command_features(files)
        features = []
        package_json = "package.json"
        if files.include?(package_json)
          data = JSON.parse(read(package_json)) rescue {}
          Array(data["bin"]).each { |entry| features << build_command_feature(entry, files) if files.include?(entry) }
          data["bin"].each_value { |entry| features << build_command_feature(entry, files) if files.include?(entry) } if data["bin"].is_a?(Hash)
          if data["scripts"].is_a?(Hash) && data["scripts"].any?
            features << build_manifest_feature("command", "package.json", "package-json-scripts", files)
          end
        end

        if files.include?("pyproject.toml")
          if project_scripts(read("pyproject.toml")).any?
            features << build_manifest_feature("command", "pyproject.toml", "pyproject-scripts", files)
          end
        end

        if files.include?("Package.swift")
          if swift_executables(read("Package.swift")).any?
            features << build_manifest_feature("command", "Package.swift", "package-swift-executables", files)
          end
        end

        files.grep(%r{\A(bin|exe)/[^/]+\z}).each { |path| features << build_command_feature(path, files) }
        files.grep(%r{\Acmd/[^/]+/main\.go\z}).each { |path| features << build_command_feature(path, files) }
        features << build_command_feature("src/main.rs", files) if files.include?("src/main.rs")
        files.grep(%r{\Asrc/bin/[^/]+\.rs\z}).each { |path| features << build_command_feature(path, files) }
        features
      end

      def build_command_feature(entrypoint, files)
        return build_feature("command", entrypoint, files) unless architecture_capability?

        Feature.new(
          id: stable_id("command", entrypoint),
          kind: "command",
          entrypoints: [ entrypoint ],
          owned_files: [ entrypoint ],
          context_files: capped(context_for(entrypoint, files), max_context_files),
          tests: capped(associated_tests(entrypoint, files), max_context_files)
        )
      end

      def architecture_features(files, separately_reviewed: [])
        reviewed_paths = separately_reviewed.flat_map(&:owned_files).to_set
        ArchitectureMapper.new(
          @project_root, cfg: @cfg, review_scope: :patrol
        ).call(files).filter_map do |feature|
          # Dedicated command-contract slices already own these paths. Keep
          # command entrypoints as component context, but never as a second
          # root-cause anchor; omit manifest components whose sole owned file
          # is already reviewed by a grouped script-contract slice.
          next if feature.owned_files.any? && feature.owned_files.all? { |path| reviewed_paths.include?(path) }

          reviewed_entrypoints = feature.entrypoints.select { |path| reviewed_paths.include?(path) }
          Feature.new(
            id: feature.id,
            kind: feature.kind,
            entrypoints: feature.entrypoints - reviewed_entrypoints,
            owned_files: feature.owned_files,
            context_files: capped(feature.context_files + reviewed_entrypoints, max_context_files),
            tests: feature.tests
          )
        end
      end

      # Parse the `[project.scripts]` table of pyproject.toml (PEP 621
      # console entrypoints). Lightweight section scan — no TOML dep is
      # available — collecting the left-hand key of each `name = "..."`
      # line until the next table header.
      def project_scripts(content)
        in_table = false
        content.each_line.filter_map do |line|
          stripped = line.strip
          if stripped.start_with?("[")
            in_table = stripped == "[project.scripts]"
            next
          end
          next unless in_table

          key = stripped[/\A["']?([\w.\-]+)["']?\s*=/, 1]
          key&.strip
        end.uniq
      end

      # Collect executable target names declared in Package.swift via
      # `.executableTarget(name: "X")`. Regex scan over the manifest text;
      # SwiftPM manifests are Swift source, not a parseable data format.
      def swift_executables(content)
        content.scan(/\.executableTarget\(\s*name:\s*["']([^"']+)["']/).flatten.uniq
      end

      def package_features(files)
        %w[package.json Gemfile pyproject.toml go.mod Cargo.toml Package.swift composer.json mix.exs].filter_map do |path|
          build_manifest_feature("package", path, path, files) if files.include?(path)
        end
      end

      def test_features(files)
        tests = files.select { |path| path.match?(%r{\A(test|tests|spec)/}) }
        return [] if tests.empty?

        [
          Feature.new(
            id: stable_id("test-suite", tests.first),
            kind: "test-suite",
            entrypoints: [ tests.first ],
            owned_files: capped(tests, max_owned_files),
            context_files: [],
            tests: capped(tests, max_context_files)
          )
        ]
      end

      def build_feature(kind, entrypoint, files)
        dir = File.dirname(entrypoint)
        owned = files.select { |path| path == entrypoint || File.dirname(path) == dir }
        tests = associated_tests(entrypoint, files)
        Feature.new(
          id: stable_id(kind, entrypoint),
          kind: kind,
          entrypoints: [ entrypoint ],
          owned_files: capped(owned, max_owned_files),
          context_files: capped(context_for(entrypoint, files), max_context_files),
          tests: capped(tests, max_context_files)
        )
      end

      def build_manifest_feature(kind, manifest, id_seed, files)
        Feature.new(
          id: stable_id(kind, id_seed),
          kind: kind,
          entrypoints: [ manifest ],
          owned_files: [ manifest ],
          context_files: capped(context_for(manifest, files), max_context_files),
          tests: capped(associated_tests(manifest, files), max_context_files)
        )
      end

      def context_for(entrypoint, files)
        top = entrypoint.split("/").first
        candidates = %w[README.md README.rdoc package.json Gemfile pyproject.toml go.mod Cargo.toml]
        candidates.select { |path| files.include?(path) } +
          files.select { |path| path.start_with?("#{top}/") && path != entrypoint }.first(3)
      end

      def associated_tests(entrypoint, files)
        stem = File.basename(entrypoint, File.extname(entrypoint))
        files.select do |path|
          path.match?(%r{\A(test|tests|spec)/}) &&
            (path.include?(stem) || path.include?(File.dirname(entrypoint)))
        end
      end

      def stable_id(kind, seed)
        slug = seed.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-+\z/, "")
        "#{kind}-#{slug}"[0, 80]
      end

      def max_owned_files
        @cfg.dig("patrol", "review", "max_owned_files") || 4
      end

      def max_context_files
        @cfg.dig("patrol", "review", "max_context_files") || 4
      end

      def capped(items, limit)
        items.uniq.first(limit)
      end

      def dedupe(features)
        features.uniq(&:id)
      end

      def read(path)
        @source_reader.read_utf8(path)
      end
    end
  end
end
