require "hive/display_name/generator"
require "hive/task_resolver"

module Hive
  module Commands
    class GenerateName
      def initialize(target, project: nil, stage: nil)
        @target = target
        @project = project
        @stage = stage
      end

      def call
        task = Hive::TaskResolver.new(
          @target,
          project_filter: @project,
          stage_filter: @stage
        ).resolve
        name = Hive::DisplayName::Generator.new(task).call
        puts name if name
        name
      end
    end
  end
end
