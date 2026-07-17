require "hive/worktree"
require "hive/markers"
require "hive/finalization/archive_cleanup"

module Hive
  module Stages
    module Done
      module_function

      def run!(task, _cfg, cleanup: nil)
        FileUtils.touch(task.state_file) unless File.exist?(task.state_file)
        cleanup ||= Hive::Finalization::ArchiveCleanup.new(task: task)
        cleanup_result = cleanup.call
        Hive::Markers.set(task.state_file, :complete)
        { commit: "archived", status: :complete,
          cleanup_instructions: cleanup_instructions(task, cleanup_result) }
      end

      def cleanup_instructions(task, cleanup)
        if cleanup.status == :already_completed
          [ "Task #{task.slug} archive cleanup already completed (receipt #{cleanup.event_id})." ]
        else
          [
            "Task #{task.slug} archived and local recovery state was removed.",
            "  worktree: #{cleanup.worktree}",
            "  local branch: #{cleanup.branch}",
            "  cleanup receipt: #{cleanup.event_id}"
          ]
        end
      end
    end
  end
end
