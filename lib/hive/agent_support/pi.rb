require "hive/agent_support"
require "hive/agent/message_extractor"
require "json"

module Hive::AgentSupport::Pi
  autoload :Runtime, "hive/agent_support/pi/runtime"
  autoload :Skills, "hive/agent_support/pi/skills"
  autoload :SetupAdapter, "hive/agent_support/pi/setup_adapter"

  module_function

  def credential_path(home: nil) = File.join(home || Dir.home, ".pi", "agent", "auth.json")
  def execution_identity(model)
    value = model.to_s
    value.include?("/") ? value.split("/", 2) : [ nil, value ]
  end
  def capture_interface_required? = true
  def validate_capture_profile!(profile:, unsupported:) = true
  def producer_interface(required_kinds:, browser:, project_server: false)
    {
      "document" => "evidence_write",
      "terminal" => required_kinds.include?("terminal") ? "evidence_terminal" : nil,
      "browser" => browser ? "evidence_browser" : nil,
      "server" => project_server ? "evidence_server" : nil
    }.compact
  end
  def prepare_capture(host:, profile:, task_folder:, package_root:, environment:,
                      mailbox_root:, writable_root:, hive_executable:, browser:, **)
    {
      permission_arguments: nil,
      runtime_policy: Runtime.compile_evidence_actor(
        host:, task_folder:, package_root:, profile:, environment:, mailbox_root:,
        writable_root:, hive_executable:, browser:
      )
    }.freeze
  end
  def default_model(**options) = Hive::ImplementationIdentity::NativeDefaults
    .resolve(:pi, **options) { |project_root:, home:| native_model(project_root:, home:) }
  def parse_token(raw)
    document = JSON.parse(raw.to_s)
    raise Hive::Error, "pi token JSON must be a non-empty object" unless document.is_a?(Hash) && document.any?

    JSON.pretty_generate(document)
  rescue JSON::ParserError => e
    raise Hive::Error, "pi token JSON is invalid: #{e.message}"
  end
  def plan_review_capability = { "status" => "present", "diagnostic" => nil, "invocation" => nil }
  def plan_review_launch_kwargs(**) = { permission_mode: nil, allowed_tools: nil, disallowed_tools: nil }
  def native_model(project_root:, home:)
    defaults = Hive::ImplementationIdentity::NativeDefaults
    defaults.json_model(
      defaults.paths(
        project_root, home, ".pi/settings.json", home_relative: ".pi/agent/settings.json"
      ),
      %w[model defaultModel], provider_keys: %w[provider defaultProvider]
    )
  end

  def extract_message(data)
    return unless data["type"] == "agent_end"

    assistant = Array(data["messages"]).reverse.find do |message|
      message.is_a?(Hash) && message["role"] == "assistant"
    end
    Hive::Agent::MessageExtractor.text_from_content(assistant && assistant["content"])
  end

  def sensitive_payload?(data, raw_line: nil)
    data.is_a?(Hash) && data["type"] == "agent_end" && data.key?("messages")
  end
end
