require "json"
require "open3"
require "pathname"
require "hive/patrol/feature"
require "hive/patrol/state_store"

module Hive
  module Patrol
    class Mapper
      DEFAULT_EXCLUDES = [ ".git", ".hive-state" ].freeze

      def initialize(project_root, cfg:, state: StateStore.new(project_root), dry_run: false)
        @project_root = File.expand_path(project_root)
        @cfg = cfg
        @state = state
        @dry_run = dry_run
      end

      def call
        # A dry run must not create durable artifacts under the state tree, so
        # skip ensure!/write_feature and only compute the mapping in memory.
        @state.ensure! unless @dry_run
        files = tracked_files
        features = []
        features.concat(route_features(files))
        features.concat(command_features(files))
        features.concat(package_features(files))
        features.concat(test_features(files))
        features = dedupe(features)
        features.each { |feature| @state.write_feature(feature) } unless @dry_run
        features
      end

      private

      def tracked_files
        out, = Open3.capture3("git", "-C", @project_root, "ls-files", "-z")
        files = out.split("\0").reject(&:empty?)
        files = Dir.glob("**/*", File::FNM_DOTMATCH, base: @project_root).select do |path|
          File.file?(File.join(@project_root, path))
        end if files.empty?

        files.map { |path| path.tr("\\", "/") }.select { |path| included?(path) }.sort
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
          Array(data["bin"]).each { |entry| features << build_feature("command", entry, files) if files.include?(entry) }
          data["bin"].each_value { |entry| features << build_feature("command", entry, files) if files.include?(entry) } if data["bin"].is_a?(Hash)
          data.fetch("scripts", {}).each_key do |name|
            features << build_manifest_feature("command", "package.json", "npm-script-#{name}", files)
          end if data["scripts"].is_a?(Hash)
        end

        if files.include?("pyproject.toml")
          project_scripts(read("pyproject.toml")).each do |name|
            features << build_manifest_feature("command", "pyproject.toml", "python-script-#{name}", files)
          end
        end

        if files.include?("Package.swift")
          swift_executables(read("Package.swift")).each do |name|
            features << build_manifest_feature("command", "Package.swift", "swift-executable-#{name}", files)
          end
        end

        files.grep(%r{\A(bin|exe)/[^/]+\z}).each { |path| features << build_feature("command", path, files) }
        files.grep(%r{\Acmd/[^/]+/main\.go\z}).each { |path| features << build_feature("command", path, files) }
        features << build_feature("command", "src/main.rs", files) if files.include?("src/main.rs")
        files.grep(%r{\Asrc/bin/[^/]+\.rs\z}).each { |path| features << build_feature("command", path, files) }
        features
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
        @cfg.dig("patrol", "review", "max_owned_files") || 12
      end

      def max_context_files
        @cfg.dig("patrol", "review", "max_context_files") || 24
      end

      def capped(items, limit)
        items.uniq.first(limit)
      end

      def dedupe(features)
        features.uniq(&:id)
      end

      def read(path)
        File.read(File.join(@project_root, path))
      rescue SystemCallError
        ""
      end
    end
  end
end
