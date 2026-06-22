require "hive"
require "hive/workflows/coding"
require "hive/workflows/content"

module Hive
  module Workflows
    class UnknownWorkflow < Hive::Error
      # The offending workflow id and the registered-workflow list travel as
      # structured fields, not only baked into the interpolated message, so an
      # agent / TUI can render a diagnosis without regex-parsing `message`.
      # Mirrors the sibling `New::UnregisteredProjectWorkflow#value` pattern —
      # this is the most agent-facing error in the workflow stack (USAGE,
      # surfaced by `--workflow`).
      attr_reader :value, :valid

      def initialize(message, value: nil, valid: nil)
        super(message)
        @value = value
        @valid = valid
      end

      # A bad `--workflow` name is a do-not-retry usage error, not a generic
      # crash — classify it like InvalidTaskPath/WrongStage so automated
      # callers see USAGE (64), not GENERIC (1).
      def exit_code
        Hive::ExitCodes::USAGE
      end
    end

    module Registry
      WORKFLOWS = {
        coding: Coding::DESCRIPTOR,
        content: Content::DESCRIPTOR
      }.freeze

      module_function

      def fetch(id)
        WORKFLOWS.fetch(id) do
          known = WORKFLOWS.keys.map(&:inspect).join(", ")
          raise UnknownWorkflow.new(
            "unknown workflow #{id.inspect}; known workflows: #{known}",
            value: id,
            valid: WORKFLOWS.keys.map(&:to_s)
          )
        end
      end

      # Uses the bare `:coding` symbol, NOT Hive::Workflows::CODING_ID: this
      # method is called at load time from stages.rb:12 (DIRS) before
      # workflows.rb has defined CODING_ID — registry.rb is required by
      # workflows.rb, so the constant is not yet reachable here. The literal is
      # the deliberate break in the require cycle, equal to CODING_ID by
      # construction (workflows_test pins them equal).
      def default
        fetch(:coding)
      end

      def all
        WORKFLOWS.values
      end

      def ids
        WORKFLOWS.keys
      end
    end
  end
end
