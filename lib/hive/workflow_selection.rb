require "hive/workflows"

module Hive
  module WorkflowSelection
    module_function

    def fetch!(name)
      raw = name.to_s.strip
      id = raw.empty? ? Hive::Workflows::CODING_ID : raw.to_sym
      Hive::Workflows::Registry.fetch(id)
    rescue Hive::Workflows::UnknownWorkflow
      raise Hive::Workflows::UnknownWorkflow.new(
        "unknown workflow #{name.inspect}; valid workflows: #{valid_names.join(', ')}",
        value: name,
        valid: valid_names
      )
    end

    def valid_names
      Hive::Workflows::Registry.ids.map(&:to_s)
    end
  end
end
