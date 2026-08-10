require "time"
require "fileutils"
require "hive/config"

module Hive
  module Babysitter
    module StatusWriter
      HEADER = "# Hive Babysitter\n\n".freeze

      module_function

      def append(project:, pr_count:, fixed:, untouched:, needs_human:, now: Time.now)
        state_path = Hive::Config.project_hive_state_path(project)
        path = File.join(state_path, "babysitter", "status.md")
        FileUtils.mkdir_p(File.dirname(path))
        line = "babysitter pass @ #{now.utc.iso8601}: #{pr_count} PRs, " \
               "#{fixed} fixed, #{untouched} untouched, #{needs_human} needs-human\n"
        File.open(path, File::WRONLY | File::APPEND | File::CREAT, 0o644) do |file|
          file.write(HEADER) if file.size.zero?
          file.write(line)
        end
        line
      end
    end
  end
end
