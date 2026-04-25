require "hive/worktree"
require "hive/markers"

module Hive
  module Stages
    module Done
      module_function

      def run!(task, _cfg)
        FileUtils.touch(task.state_file) unless File.exist?(task.state_file)
        pointer = Hive::Worktree.read_pointer(task.folder)
        if pointer && pointer["path"]
          puts "Task #{task.slug} marked done. To clean up:"
          puts "  cd #{task.project_root}"
          puts "  git worktree remove #{pointer['path']}"
          puts "  git branch -d #{pointer['branch'] || task.slug}"
          puts "(Use -D / --force if the branch was squash-merged.)"
        else
          puts "Task #{task.slug} archived. No worktree pointer; nothing to clean up."
        end
        Hive::Markers.set(task.state_file, :complete)
        { commit: "archived", status: :complete }
      end
    end
  end
end
