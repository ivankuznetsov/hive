require "hive/workflows"
require "hive/workflows/project"

module Hive
  module WorkflowSelection
    module_function

    def fetch!(name, project_root: Dir.pwd)
      Hive::Workflows::Project.with_active_workflows(project_root) do |registry, _stage_names|
        raw = name.to_s.strip
        id = raw.empty? ? Hive::Workflows::CODING_ID : raw.to_sym
        # An explicitly-named workflow (not the blank→coding default) whose
        # descriptor file exists but was skipped at load — malformed, or
        # colliding with a built-in — surfaces its real ConfigError here instead
        # of silently resolving to the built-in (collision) or raising a
        # misleading UnknownWorkflow (parse error). U9-3. The blank default never
        # triggers it so a stray `coding.yml` doesn't break `hive new` without
        # `--workflow`.
        Hive::Workflows::Project.assert_descriptor_loadable!(id, project_root: project_root) unless raw.empty?
        registry.fetch(id)
      rescue Hive::Workflows::UnknownWorkflow
        # Suggestions are part of the same resolution result. Copy them while
        # the selected project's overlay is still active so a concurrent root
        # switch cannot mix another project's names into this error.
        names = registry.ids.map(&:to_s)
        raise Hive::Workflows::UnknownWorkflow.new(
          "unknown workflow #{name.inspect}; valid workflows: #{names.join(', ')}",
          value: name,
          valid: names
        )
      end
    end

    def valid_names(project_root: nil)
      if project_root
        Hive::Workflows::Project.with_active_workflows(project_root) do |registry, _stage_names|
          registry.ids.map(&:to_s)
        end
      else
        # Compatibility for callers that intentionally want the current
        # process view without selecting a project. This is not a substitute
        # for project-specific resolution.
        Hive::Workflows::Project.synchronize do
          Hive::Workflows::Registry.ids.map(&:to_s)
        end
      end
    end
  end
end
