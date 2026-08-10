require "json"
require "stringio"

require "hive/agent_skills"
require "hive/commands/setup_agents"
require "hive/config"

module Hive
  module Web
    # Thin in-process adapter for the same Inspector and SetupAgents command
    # used by `hive doctor` / `hive setup-agents`. The browser chooses one
    # registered project at a time so opening the Agents page never inventories
    # every installed CLI, and repair carries an explicit web-consent origin.
    class AgentSkills
      def initialize(inspector_class: nil,
                     setup_command_class: Hive::Commands::SetupAgents)
        @inspector_class = inspector_class
        @setup_command_class = setup_command_class
      end

      def health(project)
        project_root, config = project_context(project)
        inspector = if @inspector_class
          @inspector_class.new(config: config, project_root: project_root)
        else
          Hive::AgentSkills.hive_inspector(config: config, project_root: project_root)
        end
        inspector.inspect.map(&:to_h)
      end

      def repair(project)
        project_root, config = project_context(project)
        output = StringIO.new
        error = StringIO.new
        exit_code = @setup_command_class.new(
          config: config,
          project_root: project_root,
          yes: true,
          json: true,
          input: StringIO.new,
          output: output,
          error: error,
          consent_provenance: "web_confirmed"
        ).call
        payload = JSON.parse(output.string)
        payload["exit_code"] = exit_code unless payload.key?("exit_code")
        payload["stderr"] = error.string.strip unless error.string.strip.empty?
        payload
      rescue JSON::ParserError
        detail = error&.string.to_s.strip
        message = "could not read agent skill setup result — run `hive setup-agents` for details"
        message = "#{message}: #{detail}" unless detail.empty?
        raise Hive::Error, message
      end

      private

      def project_context(project)
        project_root = File.expand_path(project.fetch("path"))
        [ project_root, Hive::Config.load(project_root) ]
      end
    end
  end
end
