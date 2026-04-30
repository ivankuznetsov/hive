require "hive/worktree"
require "hive/markers"

module Hive
  module Stages
    module Done
      module_function

      # Returns a result hash whose `cleanup_instructions:` carries the
      # human-readable cleanup lines as data. The caller (Hive::Commands::Run)
      # decides whether to render them on stdout (human path) or embed them in
      # the JSON envelope (--json path). Writing them directly to stdout here
      # would pollute the --json contract by emitting non-JSON bytes before
      # report_json runs.
      def run!(task, _cfg)
        FileUtils.touch(task.state_file) unless File.exist?(task.state_file)
        pointer = Hive::Worktree.read_pointer(task.folder)
        instructions = build_cleanup_instructions(task, pointer)
        Hive::Markers.set(task.state_file, :complete)
        { commit: "archived", status: :complete, cleanup_instructions: instructions }
      end

      def build_cleanup_instructions(task, pointer)
        if pointer && pointer["path"]
          [
            "Task #{task.slug} marked done. To clean up:",
            "  cd #{task.project_root}",
            "  git worktree remove #{pointer['path']}",
            "  git branch -d #{pointer['branch'] || task.slug}",
            "(Use -D / --force if the branch was squash-merged.)"
          ]
        else
          [ "Task #{task.slug} archived. No worktree pointer; nothing to clean up." ]
        end
      end
    end
  end
end
