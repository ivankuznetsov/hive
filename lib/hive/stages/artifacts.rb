require "fileutils"
require "hive/markers"

module Hive
  module Stages
    module Artifacts
      module_function

      def run!(task, _cfg)
        FileUtils.touch(task.state_file) unless File.exist?(task.state_file)
        marker = Hive::Markers.current(task.state_file)
        return { commit: nil, status: :complete } if marker.name == :complete

        Hive::Markers.set(task.state_file, :complete)
        { commit: "artifacts_collected", status: :complete }
      end
    end
  end
end
