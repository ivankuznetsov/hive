require "hive"
require "hive/workflows/coding"

module Hive
  module Workflows
    class UnknownWorkflow < Hive::Error
    end

    module Registry
      WORKFLOWS = {
        coding: Coding::DESCRIPTOR
      }.freeze

      module_function

      def fetch(id)
        WORKFLOWS.fetch(id) do
          known = WORKFLOWS.keys.map(&:inspect).join(", ")
          raise UnknownWorkflow, "unknown workflow #{id.inspect}; known workflows: #{known}"
        end
      end

      def default
        fetch(:coding)
      end
    end
  end
end
