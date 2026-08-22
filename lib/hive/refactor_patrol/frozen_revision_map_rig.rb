require "securerandom"

require "hive/config"
require "hive/git_ops"
require "hive/patrol/mapper"
require "hive/refactor_patrol/state_store"
require "hive/worktree"

module Hive
  module RefactorPatrol
    # Runs Architecture Patrol mapping in a disposable worktree pinned to one
    # exact detached revision. Callers may supply a revision or ask the rig to
    # freeze the current origin default-branch head before mapping.
    class FrozenRevisionMapRig
      Result = Data.define(:analysis_sha, :features)
      OID = /\A[0-9a-f]{40,64}\z/.freeze

      def initialize(worktree_factory: nil, mapper_factory: nil)
        @worktree_factory = worktree_factory
        @mapper_factory = mapper_factory
      end

      def call(entry:, cfg:, analysis_sha: nil)
        worktree = build_worktree(entry, cfg)
        sha = analysis_sha || fetch_origin_sha(worktree, entry, cfg)
        raise Hive::ConfigError, "Architecture Patrol map revision is invalid" unless
          OID.match?(sha.to_s)

        sha = sha.to_s
        worktree.create_detached_exact!(base_sha: sha)
        worktree.assert_detached_exact!(base_sha: sha)
        Result.new(
          analysis_sha: sha,
          features: build_mapper(worktree.path, entry, cfg).call.freeze
        )
      ensure
        worktree&.discard!(force: true)
      end

      private

      def fetch_origin_sha(worktree, entry, cfg)
        branch = cfg["default_branch"] || Hive::GitOps.new(entry.fetch("path")).detect_default_branch
        worktree.fetch_strict_origin_base!(branch)
      end

      def build_worktree(entry, cfg)
        return @worktree_factory.call(entry, cfg) if @worktree_factory

        root = entry.fetch("path")
        configured = cfg["worktree_root"] || Hive::Worktree.default_worktree_root(File.basename(root))
        Hive::Worktree.new(
          root, "map-#{Process.pid}-#{SecureRandom.hex(8)}",
          worktree_root: File.join(
            File.expand_path(configured), ".refactor-patrol", "frozen-revision-map"
          )
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
