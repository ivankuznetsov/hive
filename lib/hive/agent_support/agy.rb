require "hive/agent_support"

module Hive::AgentSupport::Agy
  # Antigravity CLI (`agy`) streams assistant text/thinking/tool progress in
  # `step_update` events and puts the final assistant reply in `result.response`
  # when `result.status == "SUCCESS"`. Those payloads carry message text and
  # stay out of durable logs and quota scans. Failed `result` envelopes
  # (`ERROR`, `CANCELED`, etc.) are deliberately not sensitive so the error
  # extractor can classify provider failures and rate limits.
  SENSITIVE_LINE = /
    "event"\s*:\s*"step_update" |
    "event"\s*:\s*"result".*"status"\s*:\s*"SUCCESS" |
    "status"\s*:\s*"SUCCESS".*"event"\s*:\s*"result"
  /ix.freeze

  ORCHESTRATOR_DISPLAY_MODELS = {
    "orchestrator (carbon)" => "gemini-pro-orchestrator",
    "orchestrator (neon)" => "gemini-pro-orchestrator-neon",
    "orchestrator (argon)" => "gemini-pro-orchestrator-argon"
  }.freeze

  autoload :Skills, "hive/agent_support/agy/skills"
  autoload :SetupAdapter, "hive/agent_support/agy/setup_adapter"
  autoload :Stream, "hive/agent_support/agy/stream"

  module_function

  def credential_path(home: nil)
    AgentCliRuntime::Profiles.agy_auth_path(home:, env: ENV)
  end

  def config_directory(environment: ENV)
    AgentCliRuntime::Profiles.fetch(:agy).configuration_directory(
      home: environment["HOME"], env: environment
    )
  end

  def state_directory(environment: ENV)
    AgentCliRuntime::Profiles.agy_state_directory(
      home: environment["HOME"], env: environment
    )
  end

  def execution_identity(model)
    [ "google", model.to_s.empty? ? nil : model.to_s ]
  end

  def plan_review_launch_kwargs(**)
    { permission_mode: nil, allowed_tools: nil, disallowed_tools: nil }
  end

  def auth_environment(environment)
    environment.except(*AgentCliRuntime::Profiles.fetch(:agy).credential_environment_keys)
  end

  def default_model(**options)
    Hive::ImplementationIdentity::NativeDefaults.resolve(:agy, **options) do |project_root:, home:|
      defaults = Hive::ImplementationIdentity::NativeDefaults
      raw = defaults.json_model(
        defaults.paths(project_root, home, ".gemini/antigravity-cli/settings.json"),
        %w[model]
      )
      normalize_settings_model(raw)
    end
  end

  # `agy` writes human display names such as "Gemini 4 Neon (XHigh)" into
  # settings.json, while `--model` and Hive implementation identities use slug
  # IDs matching `MODEL_PATTERN`. Convert known display names to their CLI
  # model slugs while passing valid IDs through unchanged.
  def normalize_settings_model(value)
    raw = value.to_s.strip
    return nil if raw.empty?
    return raw if Hive::ImplementationIdentity::MODEL_PATTERN.match?(raw)

    lowered = raw.downcase
    return ORCHESTRATOR_DISPLAY_MODELS[lowered] if ORCHESTRATOR_DISPLAY_MODELS.key?(lowered)

    if (match = raw.match(/\A([A-Za-z0-9][A-Za-z0-9.\s-]+?)\s*\(([A-Za-z0-9-]+)\)\z/))
      base = match[1].strip.downcase
      tier = match[2].strip.downcase
      base = base.gsub(/(\d)\.(\d)/, '\1-\2') if base.start_with?("claude ")
      slug = "#{base.gsub(/\s+/, '-')}-#{tier}"
      return slug if Hive::ImplementationIdentity::MODEL_PATTERN.match?(slug)
    end

    raw
  end

  def extract_message(data)
    return unless data["event"] == "result"

    result = data["result"]
    return unless result.is_a?(Hash) && result["status"].to_s.upcase == "SUCCESS"

    text = result["response"]
    text if text.is_a?(String) && !text.strip.empty?
  end

  def sensitive_payload?(data, raw_line: nil)
    if data.is_a?(Hash)
      event = data["event"].to_s
      return true if event == "step_update"
      return data.dig("result", "status").to_s.upcase == "SUCCESS" if event == "result"

      return false
    end

    raw_line.to_s.scrub.match?(SENSITIVE_LINE)
  end
end
