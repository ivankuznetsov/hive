require "time"
require "hive/events"

module Hive
  module Babysitter
    module StatusWriter
      module_function

      def append(project:, pr_count:, fixed:, untouched:, needs_human:, now: Time.now)
        path = File.join(project.fetch("hive_state_path"), "babysitter", "status.md")
        previous = File.exist?(path) ? File.read(path) : "# Hive Babysitter\n\n"
        line = "babysitter pass @ #{now.utc.iso8601}: #{pr_count} PRs, " \
               "#{fixed} fixed, #{untouched} untouched, #{needs_human} needs-human\n"
        Hive::Events.write_atomic(path, previous + line)
        line
      end
    end
  end
end
