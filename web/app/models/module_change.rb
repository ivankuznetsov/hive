class ModuleChange
  PREVIEW_PURPOSE = "hive-web-module-lifecycle".freeze
  PREVIEW_TTL = 10.minutes
  OPERATIONS = %w[install update enable disable uninstall].freeze

  attr_reader :operation, :project, :details

  delegate :[], :dig, :fetch, to: :details

  class Outcome
    attr_reader :operation, :project, :attributes

    def initialize(operation:, project:, attributes:)
      @operation = operation
      @project = project
      @attributes = attributes
    end

    def notice
      "#{attributes.fetch('name')} #{attributes.fetch('status').tr('_', ' ')}."
    end
  end

  class << self
    def preview!(operation:, project:, source: nil, name: nil, choices: {})
      operation = operation!(operation)
      details = HiveModule.lifecycle.preview(project, operation:, source:, name:, choices:)
      new(operation:, project:, details:, identity: { "source" => source, "name" => name, "choices" => choices })
    end

    def apply!(operation:, token:, consent:, grant_consents: [])
      operation = operation!(operation)
      require_consent!(operation, consent)
      receipt = verify_preview!(token, operation)
      required = Array(receipt["required_grants"]).sort
      supplied = Array(grant_consents).map(&:to_s).uniq.sort
      unless supplied == required
        raise Hive::Error, "confirm each separately disclosed module permission grant"
      end
      project = Project.find!(receipt.fetch("project"))
      result = HiveModule.lifecycle.apply(
        project, operation:, source: receipt["source"], name: receipt["name"],
        choices: receipt.fetch("choices"), receipt: receipt.fetch("module_receipt")
      )
      Outcome.new(operation:, project:, attributes: result)
    end

    private

    def require_consent!(operation, consent)
      return if consent == "module_#{operation}"
      raise Hive::Error, "confirm the reviewed module #{operation} from the Modules page"
    end

    def verify_preview!(token, operation)
      payload = verifier.verify(token, purpose: PREVIEW_PURPOSE)
      unless payload.is_a?(Hash) && payload["operation"] == operation
        raise Hive::Error, "module preview does not match this action; review it again"
      end
      payload
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      raise Hive::Error, "module preview expired or changed; review it again before applying"
    end

    def operation!(value)
      value = value.to_s
      return value if OPERATIONS.include?(value)
      raise Hive::Error, "unknown module change #{value.inspect}"
    end

    def verifier = Rails.application.message_verifier(:module_lifecycle)
  end

  def initialize(operation:, project:, details:, identity:)
    @operation = operation
    @project = project
    @details = details
    @identity = identity
  end

  def required_grants
    grants = details.dig("proposed", "grants") || {}
    grants.filter_map do |category, value|
      category if value == true || (value.respond_to?(:any?) && value.any?)
    end.sort
  end

  def token
    payload = {
      "operation" => operation, "project" => project.name,
      "module_receipt" => details.fetch("preview_receipt"),
      "required_grants" => required_grants
    }.merge(@identity)
    self.class.send(:verifier).generate(
      payload, expires_in: PREVIEW_TTL, purpose: PREVIEW_PURPOSE
    )
  end
end
