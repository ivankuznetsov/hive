require "fileutils"
require "hive/lock"
require "hive/workflow"

module Hive
  module Workflows
    module Bench
      INSTRUCTIONS_DIR = File.expand_path("../../../templates/builtins/bench", __dir__).freeze
      RUNTIME_DIR = File.join(INSTRUCTIONS_DIR, "runtime").freeze
      RUNTIME_STATE_DIR = "bench-runtime".freeze

      def self.instruction(name)
        File.join(INSTRUCTIONS_DIR, "#{name}.md").freeze
      end

      # A bench task must remain runnable after installation without requiring a
      # separate hive-bench checkout. Snapshot the packaged harness into the
      # project's durable hive/state branch so every campaign uses the runtime
      # version selected when the workflow was initialized.
      def self.install_runtime!(ops)
        destination = File.join(ops.hive_state_path, RUNTIME_STATE_DIR)
        staging = "#{destination}.tmp-#{Process.pid}"
        FileUtils.rm_rf(staging)
        FileUtils.mkdir_p(staging)
        FileUtils.cp_r(File.join(RUNTIME_DIR, "."), staging)

        Hive::Lock.with_commit_lock(ops.hive_state_path) do
          FileUtils.rm_rf(destination)
          FileUtils.mv(staging, destination)
          ops.hive_commit(
            stage_name: "config",
            slug: "bench-runtime",
            action: "install",
            pathspecs: [ RUNTIME_STATE_DIR ]
          )
        end
        destination
      ensure
        FileUtils.rm_rf(staging) if staging
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
            agent: "codex",
            timeout_sec: 3600,
            status_mode: :state_file_marker
          ),
          Hive::Workflow::Stage.new(
            name: "generate",
            index: 3,
            state_file: "generate.md",
            advance_verb: Hive::Workflow::AdvanceVerb.new(name: "generate"),
            kind: :agent,
            instruction: instruction("generate"),
            agent: "codex",
            timeout_sec: 604_800,
            status_mode: :state_file_marker
          ),
          Hive::Workflow::Stage.new(
            name: "judge",
            index: 4,
            state_file: "judge.md",
            advance_verb: Hive::Workflow::AdvanceVerb.new(name: "judge"),
            kind: :agent,
            instruction: instruction("judge"),
            agent: "codex",
            timeout_sec: 604_800,
            status_mode: :state_file_marker
          ),
          Hive::Workflow::Stage.new(
            name: "publish",
            index: 5,
            state_file: "publish.md",
            advance_verb: Hive::Workflow::AdvanceVerb.new(name: "publish"),
            kind: :agent,
            instruction: instruction("publish"),
            agent: "codex",
            timeout_sec: 3600,
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
