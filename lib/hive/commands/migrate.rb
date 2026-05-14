require "fileutils"
require "open3"
require "yaml"
require "hive/config"
require "hive/git_ops"
require "hive/lock"
require "hive/stages"

module Hive
  module Commands
    class Migrate
      STAGE_RENAMES = {
        "5-review" => "6-review",
        "6-pr" => "7-finalize",
        "7-done" => "8-done"
      }.freeze

      # Legacy `pr` budget/timeout keys are read-through-fallback in
      # Stages::Finalize for one version; this map rewrites them onto
      # the canonical names so the shim has a removal path. New keys
      # win on collision (the canonical was the one the user actually
      # tuned post-migration).
      CONFIG_KEY_RENAMES = {
        %w[budget_usd pr] => %w[budget_usd finalize],
        %w[timeout_sec pr] => %w[timeout_sec finalize]
      }.freeze

      # Task-folder names follow this slug pattern (see Task::PATH_RE).
      # Any entry under a legacy stage directory that doesn't look like a
      # task slug is left in place — never silently mv'd into the new
      # stage dir.
      SLUG_RE = /\A[a-z][a-z0-9-]{0,62}[a-z0-9]\z/

      def initialize(project_path = Dir.pwd)
        @project_path = File.expand_path(project_path)
      end

      def call
        hive_state = File.join(@project_path, ".hive-state")
        stages = File.join(hive_state, "stages")
        raise Hive::InvalidTaskPath, "not a hive project: #{hive_state}" unless Dir.exist?(stages)

        moved = []
        Hive::Lock.with_commit_lock(hive_state) do
          plan = build_migration_plan(stages)
          config_changed = rewrite_legacy_config_keys(hive_state)
          if plan.empty?
            ensure_current_stage_dirs(stages)
            if config_changed
              commit_migration(hive_state, moved)
              puts "hive: migrate rewrote legacy config keys (no task folders to move)"
            elsif already_migrated?(stages)
              puts "hive: migrate found nothing to move (target stage directories look already-migrated)"
            else
              puts "hive: migrate found nothing to move"
            end
            return moved
          end

          # Pre-flight: all destinations must be free BEFORE we issue
          # any `mv`. Mid-loop collisions left the filesystem partially
          # renamed with no rollback — pre-flighting closes that hole.
          preflight_collisions!(plan)
          plan.each { |op| FileUtils.mv(op[:src], op[:dst]) }
          moved.concat(plan.map { |op| [ op[:old_stage], op[:new_stage], op[:entry] ] })
          ensure_current_stage_dirs(stages)
          commit_migration(hive_state, moved)
        end

        puts "hive: migrate complete (#{moved.size} task#{moved.size == 1 ? '' : 's'} moved)"
        moved
      end

      private

      def build_migration_plan(stages)
        ops = []
        STAGE_RENAMES.each do |old_stage, new_stage|
          old_dir = File.join(stages, old_stage)
          new_dir = File.join(stages, new_stage)
          FileUtils.mkdir_p(new_dir)
          next unless Dir.exist?(old_dir)

          Dir.children(old_dir).sort.each do |entry|
            # Skip any non-slug entry (including .gitkeep, .DS_Store,
            # stray .lock, etc.). Only task-folder slugs migrate.
            next unless SLUG_RE.match?(entry)

            src = File.join(old_dir, entry)
            next unless File.directory?(src)

            ops << {
              old_stage: old_stage, new_stage: new_stage, entry: entry,
              src: src, dst: File.join(new_dir, entry)
            }
          end
        end
        ops
      end

      def preflight_collisions!(plan)
        collisions = plan.select { |op| File.exist?(op[:dst]) }
        return if collisions.empty?

        first = collisions.first
        raise Hive::DestinationCollision.new(
          "cannot migrate #{collisions.size} task#{collisions.size == 1 ? '' : 's'}; " \
          "destination already exists for #{first[:old_stage]}/#{first[:entry]} at #{first[:dst]}",
          path: first[:dst]
        )
      end

      def ensure_current_stage_dirs(stages)
        Hive::Stages::DIRS.each do |stage|
          dir = File.join(stages, stage)
          FileUtils.mkdir_p(dir)
          gitkeep = File.join(dir, ".gitkeep")
          FileUtils.touch(gitkeep) unless File.exist?(gitkeep)
        end
      end

      def commit_migration(hive_state, moved)
        ops = Hive::GitOps.new(@project_path)
        ops.run_git!("-C", hive_state, "add", "-A")
        _out, _err, status = Open3.capture3("git", "-C", hive_state, "diff", "--cached", "--quiet")
        return if status.success?

        ops.run_git!("-C", hive_state, "commit", "-m", "hive: migrate stage directories (#{moved.size} task#{moved.size == 1 ? '' : 's'})")
      end

      # Rewrite legacy `pr` budget/timeout keys onto the canonical
      # `finalize` names so the read-through fallback in Stages::Finalize
      # has a removal path. Idempotent and a no-op when the legacy keys
      # don't exist.
      def rewrite_legacy_config_keys(hive_state)
        path = File.join(hive_state, "config.yml")
        return false unless File.exist?(path)

        cfg = YAML.safe_load(File.read(path), permitted_classes: [ Symbol ])
        return false unless cfg.is_a?(Hash)

        changed = false
        CONFIG_KEY_RENAMES.each do |from, to|
          section, key = from
          next unless cfg.is_a?(Hash) && cfg[section].is_a?(Hash) && cfg[section].key?(key)

          legacy_value = cfg[section].delete(key)
          dst_section, dst_key = to
          cfg[dst_section] ||= {}
          cfg[dst_section][dst_key] ||= legacy_value
          changed = true
        end
        File.write(path, cfg.to_yaml) if changed
        changed
      end

      # True when every legacy stage dir is absent and every target
      # stage dir exists — i.e. an idempotent rerun of an already-
      # complete migration.
      def already_migrated?(stages)
        STAGE_RENAMES.all? { |old, new_dir| !Dir.exist?(File.join(stages, old)) && Dir.exist?(File.join(stages, new_dir)) }
      end
    end
  end
end
