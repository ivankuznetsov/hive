module Hive
  module TaskWorkspace
    class Limits
      DEFAULTS = {
        workspace_bytes: 2 * 1024 * 1024,
        artifact_bytes: 512 * 1024,
        artifact_total_bytes: 2 * 1024 * 1024,
        artifact_files: 20,
        projection_snapshot_bytes: 512 * 1024,
        journal_suffix_bytes: 1024 * 1024,
        journal_events: 2_000,
        predecessor_fetches: 32,
        attempt_bytes: 512 * 1024,
        usage_sessions_per_attempt: 100,
        usage_deadline_seconds: 2,
        timeline_material_items: 200,
        timeline_noise_groups: 100,
        timeline_bytes: 512 * 1024,
        timeline_raw_members: 20,
        timeline_clock_skew_seconds: 5 * 60,
        dependency_projects: 32,
        dependency_entries: 10_000,
        dependency_nodes: 100,
        dependency_edges: 200,
        dependency_depth: 20,
        dependency_bytes: 4 * 1024 * 1024,
        dependency_deadline_seconds: 2,
        local_git_commits: 50,
        local_git_bytes: 512 * 1024,
        local_git_deadline_seconds: 10,
        github_checks: 100,
        github_pr_text_bytes: 64 * 1024,
        github_response_bytes: 256 * 1024,
        github_deadline_seconds: 10,
        publication_cache_entry_bytes: 256 * 1024,
        publication_cache_principal_bytes: 32 * 1024 * 1024,
        publication_fresh_seconds: 2 * 60,
        publication_stale_seconds: 24 * 60 * 60,
        publication_refresh_interval_seconds: 60
      }.freeze

      def initialize(**overrides)
        unknown = overrides.keys - DEFAULTS.keys
        raise ArgumentError, "unknown workspace limits: #{unknown.join(', ')}" if unknown.any?

        @values = DEFAULTS.merge(overrides).each_with_object({}) do |(name, value), values|
          integer = Integer(value)
          raise ArgumentError, "#{name} must be positive" unless integer.positive?

          values[name] = integer
        end.freeze
      end

      def fetch(name)
        @values.fetch(name.to_sym)
      end

      def [](name)
        fetch(name)
      end

      def to_h
        @values.dup
      end
    end
  end
end
