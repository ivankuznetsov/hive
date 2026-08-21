require "digest"
require "hive/config"
require "hive/refactor_patrol/frozen_revision_map_rig"
require "hive/refactor_patrol/pr_manifest"

module Hive
  module RefactorPatrol
    # Maps immutable merged-PR paths onto the stable Architecture Patrol slice
    # ids at one controller-selected current-main commit. Every input path is
    # retained; paths outside a mapped owned boundary receive a deterministic
    # path-local id so provenance can never disappear.
    class PostMergeSliceMapper
      Mapping = Data.define(:analysis_sha, :path_mappings)

      def initialize(rig: nil, worktree_factory: nil, mapper_factory: nil)
        @rig = rig || FrozenRevisionMapRig.new(
          worktree_factory: worktree_factory, mapper_factory: mapper_factory
        )
      end

      def call(entry:, cfg:, analysis_sha:, paths:)
        sha = analysis_sha.to_s
        unless sha.match?(/\A[0-9a-f]{40,64}\z/)
          raise Hive::ConfigError, "post-merge batch analysis commit is invalid"
        end
        scope = normalize_paths(paths)
        revision_map = @rig.call(entry: entry, cfg: cfg, analysis_sha: sha)
        owners = revision_map.features.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |feature, indexed|
          Array(feature.owned_files).each { |path| indexed[path.to_s] << feature.id.to_s }
        end
        mapped = scope.map do |path|
          slice_ids = owners.fetch(path, []).reject(&:empty?).uniq.sort
          slice_ids = [ "path-#{Digest::SHA256.hexdigest(path)[0, 24]}" ] if slice_ids.empty?
          { "path" => path, "slice_ids" => slice_ids }
        end
        Mapping.new(analysis_sha: sha, path_mappings: mapped.freeze)
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
    end
  end
end
