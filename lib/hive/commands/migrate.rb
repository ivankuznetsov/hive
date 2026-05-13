require "fileutils"
require "open3"
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

      def initialize(project_path = Dir.pwd)
        @project_path = File.expand_path(project_path)
      end

      def call
        hive_state = File.join(@project_path, ".hive-state")
        stages = File.join(hive_state, "stages")
        raise Hive::InvalidTaskPath, "not a hive project: #{hive_state}" unless Dir.exist?(stages)

        moved = []
        Hive::Lock.with_commit_lock(hive_state) do
          STAGE_RENAMES.each do |old_stage, new_stage|
            moved.concat(rename_stage(stages, old_stage, new_stage))
          end
          ensure_current_stage_dirs(stages)
          commit_migration(hive_state, moved)
        end

        puts "hive: migrate complete (#{moved.size} task#{moved.size == 1 ? '' : 's'} moved)"
        moved
      end

      private

      def rename_stage(stages, old_stage, new_stage)
        old_dir = File.join(stages, old_stage)
        new_dir = File.join(stages, new_stage)
        FileUtils.mkdir_p(new_dir)
        return [] unless Dir.exist?(old_dir)

        moved = []
        Dir.children(old_dir).sort.each do |entry|
          next if entry == ".gitkeep"

          src = File.join(old_dir, entry)
          next unless File.directory?(src)

          dst = File.join(new_dir, entry)
          if File.exist?(dst)
            raise Hive::DestinationCollision.new(
              "cannot migrate #{old_stage}/#{entry}: destination already exists at #{dst}",
              path: dst
            )
          end
          FileUtils.mv(src, dst)
          moved << [ old_stage, new_stage, entry ]
        end
        moved
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
        ops.run_git!("-C", hive_state, "add", "-A", "stages")
        _out, _err, status = Open3.capture3("git", "-C", hive_state, "diff", "--cached", "--quiet")
        return if status.success?

        ops.run_git!("-C", hive_state, "commit", "-m", "hive: migrate stage directories")
      end
    end
  end
end
