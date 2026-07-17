module Hive
  module Daemon
    # Preserved-work evidence only. Dirty worktrees and artifacts are never a
    # retry eligibility gate and never reset the coordinator ladder.
    module AutoRetrySafety
      module_function

      def preservation_context(row)
        {
          "folder_present" => File.directory?(row.folder.to_s),
          "state_file_present" => File.file?(row.state_file.to_s)
        }
      rescue SystemCallError
        { "folder_present" => false, "state_file_present" => false }
      end
    end
  end
end
