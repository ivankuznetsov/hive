require "digest"
require "securerandom"
require "hive/config"
require "hive/patrol/mapper"
require "hive/refactor_patrol/pr_manifest"
require "hive/refactor_patrol/state_store"
require "hive/worktree"

module Hive
  module RefactorPatrol
    # Maps immutable merged-PR paths onto the stable Architecture Patrol slice
    # ids at one controller-selected current-main commit. Every input path is
    # retained; paths outside a mapped owned boundary receive a deterministic
    # path-local id so provenance can never disappear.
    class PostMergeSliceMapper
      Mapping = Data.define(:analysis_sha, :path_mappings)

      def initialize(worktree_factory: nil, mapper_factory: nil)
        @worktree_factory = worktree_factory
        @mapper_factory = mapper_factory
      end

      def call(entry:, cfg:, analysis_sha:, paths:)
        sha = analysis_sha.to_s
        unless sha.match?(/\A[0-9a-f]{40,64}\z/)
          raise Hive::ConfigError, "post-merge batch analysis commit is invalid"
        end
        scope = normalize_paths(paths)
        worktree = build_worktree(entry, cfg)
        worktree.create_detached_exact!(base_sha: sha)
        worktree.assert_detached_exact!(base_sha: sha)
        features = build_mapper(worktree.path, entry, cfg).call
        owners = features.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |feature, indexed|
          Array(feature.owned_files).each { |path| indexed[path.to_s] << feature.id.to_s }
        end
        mapped = scope.map do |path|
          slice_ids = owners.fetch(path, []).reject(&:empty?).uniq.sort
          slice_ids = [ "path-#{Digest::SHA256.hexdigest(path)[0, 24]}" ] if slice_ids.empty?
          { "path" => path, "slice_ids" => slice_ids }
        end
        Mapping.new(analysis_sha: sha, path_mappings: mapped.freeze)
      ensure
        worktree&.remove!(force: true) if worktree&.exists?
      end

      private

      def normalize_paths(paths)
        value = Array(paths).map(&:to_s)
        unless value.size.between?(1, 10_000) && value.uniq == value &&
               value.all? { |path| PrManifest.valid_relative_path?(path) && path.bytesize <= 4_096 }
          raise Hive::ConfigError, "post-merge batch path scope is invalid"
        end
        value
      end

      def build_worktree(entry, cfg)
        return @worktree_factory.call(entry, cfg) if @worktree_factory

        root = entry.fetch("path")
        configured = cfg["worktree_root"] || Hive::Worktree.default_worktree_root(File.basename(root))
        Hive::Worktree.new(
          root, "map-#{Process.pid}-#{SecureRandom.hex(8)}",
          worktree_root: File.join(File.expand_path(configured), ".refactor-patrol", "post-merge-map")
        )
      end

      def build_mapper(root, entry, cfg)
        return @mapper_factory.call(root, entry, cfg) if @mapper_factory

        mapped_cfg = Hive::Config.deep_dup(cfg)
        mapped_cfg["patrol"] = (mapped_cfg["patrol"] || {}).merge(
          "include" => cfg.dig("refactor_patrol", "include"),
          "exclude" => cfg.dig("refactor_patrol", "exclude"),
          "review" => cfg.dig("refactor_patrol", "review")
        )
        Hive::Patrol::Mapper.new(
          root, cfg: mapped_cfg,
          state: Hive::RefactorPatrol::StateStore.new(
            entry.fetch("path"), hive_state_path: entry.fetch("hive_state_path")
          ),
          dry_run: true, capabilities: %i[architecture documentation]
        )
      end
    end
  end
end
