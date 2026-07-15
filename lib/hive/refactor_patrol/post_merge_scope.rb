require "pathname"
require "hive/config"
require "hive/patrol/mapper"
require "hive/patrol/state_store"

module Hive
  module RefactorPatrol
    # Converts one merge's changed paths into the narrowest safe command scope.
    # A non-runnable Result is intentional fail-closed behavior: callers must
    # never omit scope flags and fall back to repository-wide discovery.
    class PostMergeScope
      Result = Struct.new(:runnable, :reason, :evidence, :kind, :values, :fallback, :base_sha, keyword_init: true) do
        def runnable?
          runnable == true
        end

        def arguments
          return [] unless runnable?

          args = [ "--changed-since", base_sha ]
          flag = "--#{kind}"
          values.each { |value| args.concat([ flag, value ]) }
          args
        end

        def to_h
          return nil unless runnable?

          { "kind" => kind, "values" => values, "fallback" => fallback }
        end
      end

      SAFE_PATH = %r{\A[A-Za-z0-9_.\-/]+\z}

      def initialize(project_root, cfg:, mapper_factory: nil)
        @project_root = File.realpath(project_root)
        @cfg = cfg
        @mapper_factory = mapper_factory || lambda do |root, config|
          Hive::Patrol::Mapper.new(
            root,
            cfg: mapper_cfg(config),
            state: Hive::Patrol::StateStore.new(root),
            dry_run: true
          )
        end
      end

      def select(changed_paths:, base_sha:)
        base = normalize_base(base_sha)
        normalized, rejected = normalize_changed_paths(changed_paths)
        return unusable("unsafe_changed_paths", "paths" => rejected) unless rejected.empty?

        included = normalized.select { |path| included?(path) }
        return unusable("no_bounded_changed_paths") if included.empty?

        features = Array(@mapper_factory.call(@project_root, @cfg).call)
        covering = features.select { |feature| covers?(feature, included, boundary: false) }
        return runnable("feature", [ covering.first.id ], base, fallback: false) if covering.one?

        entrypoint_owners = features.select do |feature|
          Array(feature.entrypoints).one? && covers?(feature, included, boundary: true)
        end
        if entrypoint_owners.one?
          return runnable("entrypoint", [ entrypoint_owners.first.entrypoints.first ], base, fallback: false)
        end

        roots = changed_roots(included)
        return unusable("no_non_root_scope") if roots.empty? || roots.include?(".")

        runnable("path", roots, base, fallback: true)
      rescue Hive::ConfigError
        raise
      rescue StandardError => e
        unusable("scope_selection_failed", "error" => "#{e.class}: #{e.message}")
      end

      private

      def runnable(kind, values, base, fallback:)
        Result.new(
          runnable: true,
          reason: nil,
          evidence: {},
          kind: kind,
          values: values.map(&:to_s).uniq.sort,
          fallback: fallback,
          base_sha: base
        )
      end

      def unusable(detail, evidence = {})
        Result.new(
          runnable: false,
          reason: "scope_unusable",
          evidence: { "detail" => detail }.merge(evidence),
          kind: nil,
          values: [],
          fallback: false,
          base_sha: nil
        )
      end

      def normalize_base(value)
        base = value.to_s
        unless base.match?(%r{\A[0-9A-Za-z][0-9A-Za-z._\-/]*\z})
          raise Hive::ConfigError, "post-merge changed-since boundary is invalid"
        end

        base
      end

      def normalize_changed_paths(paths)
        normalized = []
        rejected = []
        Array(paths).each do |raw|
          path = normalize_path(raw)
          path ? normalized << path : rejected << raw.to_s
        end
        [ normalized.uniq.sort, rejected ]
      end

      def normalize_path(raw)
        value = raw.to_s.tr("\\", "/")
        return nil if value.empty? || value.start_with?("/", "-") || !value.match?(SAFE_PATH)

        parts = value.split("/")
        return nil if parts.any? { |part| part.empty? || %w[. ..].include?(part) }

        clean = Pathname.new(value).cleanpath.to_s
        expanded = File.expand_path(clean, @project_root)
        return nil unless expanded.start_with?("#{@project_root}#{File::SEPARATOR}")

        clean
      end

      def included?(path)
        return false if path.split("/").any? { |part| %w[.git .hive-state].include?(part) }

        excludes = Array(@cfg.dig("refactor_patrol", "exclude"))
        return false if excludes.any? { |glob| glob_match?(glob, path) }

        includes = Array(@cfg.dig("refactor_patrol", "include"))
        includes.empty? || includes.any? { |glob| glob_match?(glob, path) }
      end

      def glob_match?(glob, path)
        normalized = glob.to_s.tr("\\", "/")
        File.fnmatch?(normalized, path, File::FNM_PATHNAME | File::FNM_EXTGLOB) ||
          path == normalized || path.start_with?("#{normalized}/")
      end

      def covers?(feature, paths, boundary:)
        owned = Array(feature.owned_files).map { |path| path.to_s.tr("\\", "/") }
        if boundary
          owned += Array(feature.context_files).map { |path| path.to_s.tr("\\", "/") }
          owned += Array(feature.tests).map { |path| path.to_s.tr("\\", "/") }
        end
        paths.all? { |path| owned.include?(path) }
      end

      def changed_roots(paths)
        root_files, nested = paths.partition { |path| !path.include?("/") }
        roots = root_files.dup
        nested.group_by { |path| path.split("/").first }.each_value do |group|
          directories = group.map { |path| path.split("/")[0...-1] }
          common = directories.shift || []
          directories.each do |parts|
            common = common.zip(parts).take_while { |left, right| left == right }.map(&:first)
          end
          roots << common.join("/") unless common.empty?
        end
        roots.reject { |path| path.empty? || path == "." }.uniq.sort
      end

      def mapper_cfg(cfg)
        clone = Hive::Config.deep_dup(cfg)
        clone["patrol"] = (clone["patrol"] || {}).merge(
          "include" => cfg.dig("refactor_patrol", "include"),
          "exclude" => cfg.dig("refactor_patrol", "exclude"),
          "review" => cfg.dig("refactor_patrol", "review")
        )
        clone
      end
    end
  end
end
