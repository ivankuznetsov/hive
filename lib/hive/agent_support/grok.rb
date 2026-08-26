require "json"
require "hive/agent_support"

module Hive::AgentSupport::Grok
  END_TYPE_FIELD = /"type"\s*:\s*"end"/.freeze
  STRUCTURED_OUTPUT_FIELD = /"structuredOutput"\s*:/.freeze

  autoload :Runtime, "hive/agent_support/grok/runtime"
  autoload :Skills, "hive/agent_support/grok/skills"
  autoload :SetupAdapter, "hive/agent_support/grok/setup_adapter"

  module_function

  def credential_path(home: nil) = AgentCliRuntime::Profiles.grok_auth_path(home:, env: ENV)
  def execution_identity(model) = [ "xai", model.to_s.empty? ? nil : model.to_s ]
  def auth_environment(environment) = environment.except("XAI_API_KEY", "GROK_CODE_XAI_API_KEY")
  def default_model(**options)
    Hive::ImplementationIdentity::NativeDefaults.resolve(:grok, **options) do |project_root:, home:|
      defaults = Hive::ImplementationIdentity::NativeDefaults
      defaults.json_model(defaults.paths(project_root, home, ".grok/settings.json"), %w[model defaultModel]) ||
        defaults.toml_model(defaults.paths(project_root, home, ".grok/config.toml"))
    end
  end

  def extract_message(data)
    output = data["structuredOutput"] if data["type"] == "end"
    JSON.generate(output) if output.is_a?(Hash)
  end

  def sensitive_payload?(data, raw_line: nil)
    return data["type"] == "end" && data.key?("structuredOutput") if data.is_a?(Hash)

    text = raw_line.to_s.scrub
    text.match?(END_TYPE_FIELD) && text.match?(STRUCTURED_OUTPUT_FIELD)
  end
end
