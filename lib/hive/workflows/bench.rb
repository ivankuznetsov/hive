require "hive/workflow"

module Hive
  module Workflows
    module Bench
      INSTRUCTIONS_DIR = File.expand_path("../../../templates/builtins/bench", __dir__).freeze

      def self.instruction(name)
        File.join(INSTRUCTIONS_DIR, "#{name}.md").freeze
      end

      DESCRIPTOR = Hive::Workflow.new(
        id: :bench,
        stages: [
          Hive::Workflow::Stage.new(
            name: "inbox",
            index: 1,
            state_file: "task.md",
            kind: :inert
          ),
          Hive::Workflow::Stage.new(
            name: "extract",
            index: 2,
            state_file: "extract.md",
            advance_verb: Hive::Workflow::AdvanceVerb.new(name: "extract"),
            kind: :agent,
            instruction: instruction("extract"),
            status_mode: :state_file_marker
          ),
          Hive::Workflow::Stage.new(
            name: "generate",
            index: 3,
            state_file: "generate.md",
            advance_verb: Hive::Workflow::AdvanceVerb.new(name: "generate"),
            kind: :agent,
            instruction: instruction("generate"),
            status_mode: :state_file_marker
          ),
          Hive::Workflow::Stage.new(
            name: "judge",
            index: 4,
            state_file: "judge.md",
            advance_verb: Hive::Workflow::AdvanceVerb.new(name: "judge"),
            kind: :agent,
            instruction: instruction("judge"),
            status_mode: :state_file_marker
          ),
          Hive::Workflow::Stage.new(
            name: "publish",
            index: 5,
            state_file: "publish.md",
            advance_verb: Hive::Workflow::AdvanceVerb.new(name: "publish"),
            kind: :agent,
            instruction: instruction("publish"),
            status_mode: :state_file_marker
          ),
          Hive::Workflow::Stage.new(
            name: "done",
            index: 6,
            state_file: "task.md",
            kind: :inert
          )
        ]
      )
    end
  end
end
