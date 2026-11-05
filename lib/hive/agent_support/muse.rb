require "hive/agent_support"

module Hive::AgentSupport::Muse
  # Muse's MSP event stream echoes the full prompt on turn.input.user and
  # run.lifecycle.started, streams assistant text on run.output.delta, and
  # puts the final message on run.terminal.completed. Those payloads are
  # message-bearing, so they stay out of durable logs and quota scans; only
  # the terminal text becomes the run's final message. Failed terminals are
  # deliberately not sensitive: their reason is the provider-error evidence
  # the reader extracts, and it carries no message text.
  SENSITIVE_PAYLOAD_TYPES = %w[
    turn.input.user run.lifecycle.started run.output.delta
    run.terminal.completed
  ].freeze
  SENSITIVE_LINE = /
    "payload_type"\s*:\s*"
    (?:turn\.input\.user|run\.lifecycle\.started|run\.output\.delta|
       run\.terminal\.completed)
  /x.freeze

  autoload :PluginStaging, "hive/agent_support/muse/plugin_staging"
  autoload :Skills, "hive/agent_support/muse/skills"
  autoload :SetupAdapter, "hive/agent_support/muse/setup_adapter"

  module_function

  def credential_path(home: nil) = AgentCliRuntime::Profiles.muse_auth_path(home:, env: ENV)
  def config_directory(environment: ENV)
    AgentCliRuntime::Profiles.muse_configuration_directory(
      home: environment["HOME"], env: environment
    )
  end
  def data_directory(environment: ENV)
    AgentCliRuntime::Profiles.muse_data_directory(
      home: environment["HOME"], env: environment
    )
  end
  def execution_identity(model) = [ "meta", model.to_s.empty? ? nil : model.to_s ]
  def auth_environment(environment) = environment.except("META_API_KEY")
  def default_model(**options)
    Hive::ImplementationIdentity::NativeDefaults.resolve(:muse, **options) do |project_root:, home:|
      defaults = Hive::ImplementationIdentity::NativeDefaults
      defaults.json_model(
        defaults.paths(project_root, home, ".config/muse/settings.json"), %w[model]
      )
    end
  end

  def extract_message(data)
    return unless data["payload_type"] == "run.terminal.completed"

    payload = data["payload"]
    text = payload["text"] if payload.is_a?(Hash)
    text if text.is_a?(String) && !text.strip.empty?
  end

  def sensitive_payload?(data, raw_line: nil)
    if data.is_a?(Hash)
      return SENSITIVE_PAYLOAD_TYPES.include?(data["payload_type"].to_s)
    end

    raw_line.to_s.scrub.match?(SENSITIVE_LINE)
  end
end
