require "hive/workflows"
require "hive/workflows/project"

module Hive
  module WorkflowSelection
    module_function

    def fetch!(name, project_root: Dir.pwd)
      Hive::Workflows::Project.load!(project_root)
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

    def valid_names(project_root: nil)
      Hive::Workflows::Project.load!(project_root) if project_root
      Hive::Workflows::Registry.ids.map(&:to_s)
    end
  end
end
