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
      # Thread project_root through so the valid-names list includes THIS
      # project's owner-authored workflows — a bare valid_names (project_root:
      # nil) skips loading them and could omit the very workflow the user named.
      names = valid_names(project_root: project_root)
      raise Hive::Workflows::UnknownWorkflow.new(
        "unknown workflow #{name.inspect}; valid workflows: #{names.join(', ')}",
        value: name,
        valid: names
      )
    end

    def valid_names(project_root: nil)
      Hive::Workflows::Project.load!(project_root) if project_root
      Hive::Workflows::Registry.ids.map(&:to_s)
    end
  end
end
