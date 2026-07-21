class WorkflowChange
  PREVIEW_PURPOSE = "hive-web-workflow-lifecycle".freeze
  PREVIEW_TTL = 15.minutes
  OPERATIONS = %w[install update remove].freeze
  EXPECTED_ATTRIBUTES = {
    "install" => %w[name version catalog_commit source_commit manifest_digest configuration_digest],
    "update" => %w[
      from_commit from_manifest_digest from_configuration_digest
      to_commit manifest_digest configuration_digest
    ],
    "remove" => %w[source_commit manifest_digest configuration_digest]
  }.freeze

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
      return removal_notice if operation == "remove"

      "#{attributes.fetch('name')} #{status_message}."
    end

    def alert
      warnings = Array(attributes["warnings"])
      return if warnings.empty?

      "Workflow change completed with warnings: #{warnings.join('; ')}"
    end

    private

    def removal_notice
      "#{attributes.fetch('name')} removed for new tasks; " \
        "#{attributes.fetch('retained_commits').length} task-pinned generation(s) retained."
    end

    def status_message
      case attributes.fetch("status")
      when "installed" then "installed"
      when "already_installed" then "was already installed"
      when "updated" then "updated"
      when "already_current" then "was already current"
      else attributes.fetch("status").tr("_", " ")
      end
    end
  end

  class << self
    def preview!(operation:, project:, source: nil, name: nil)
      operation = operation!(operation)
      attributes, identity = preview_attributes(operation, project, source:, name:)
      new(operation:, project:, details: attributes, identity:)
    end

    def apply!(operation:, token:, consent:, allow_escalation: nil)
      operation = operation!(operation)
      require_consent!(operation, consent)
      receipt = verify_preview!(token, operation)
      if receipt["escalation"] && allow_escalation != "1"
        raise Hive::Error, "confirm the separately disclosed security escalation before updating"
      end

      project = Project.find!(receipt.fetch("project"))
      result = apply_receipt(operation, project, receipt)
      Outcome.new(operation:, project:, attributes: result)
    end

    private

    def preview_attributes(operation, project, source:, name:)
      case operation
      when "install"
        source = source.to_s.strip
        [ Workflow.lifecycle.preview_install(project, source:), { "source" => source } ]
      when "update"
        [ Workflow.lifecycle.preview_update(project, name: name.to_s), { "name" => name.to_s } ]
      when "remove"
        [ Workflow.lifecycle.preview_remove(project, name: name.to_s), { "name" => name.to_s } ]
      end
    end

    def apply_receipt(operation, project, receipt)
      case operation
      when "install"
        Workflow.lifecycle.install(
          project, source: receipt.fetch("source"), expected: receipt.fetch("expected")
        )
      when "update"
        Workflow.lifecycle.update(
          project,
          name: receipt.fetch("name"),
          expected: receipt.fetch("expected"),
          allow_escalation: receipt["escalation"] == true
        )
      when "remove"
        Workflow.lifecycle.remove(
          project, name: receipt.fetch("name"), expected: receipt.fetch("expected")
        )
      end
    end

    def require_consent!(operation, consent)
      return if consent == "workflow_#{operation}"

      raise Hive::Error, "confirm the reviewed workflow #{operation} from the Workflows page"
    end

    def verify_preview!(token, operation)
      payload = verifier.verify(token, purpose: PREVIEW_PURPOSE)
      unless payload.is_a?(Hash) && payload["operation"] == operation
        raise Hive::Error, "workflow preview does not match this action; review it again"
      end

      payload
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      raise Hive::Error, "workflow preview expired or changed; review it again before applying"
    end

    def operation!(value)
      value = value.to_s
      return value if OPERATIONS.include?(value)

      raise Hive::Error, "unknown workflow change #{value.inspect}"
    end

    def verifier
      Rails.application.message_verifier(:workflow_lifecycle)
    end
  end

  def initialize(operation:, project:, details:, identity:)
    @operation = operation
    @project = project
    @details = details
    @identity = identity
  end

  def already_current?
    operation == "update" && details.fetch("status") == "already_current"
  end

  def escalation?
    operation == "update" && details.dig("diff", "escalation") == true
  end

  def token
    payload = {
      "operation" => operation,
      "project" => project.name,
      "expected" => details.slice(*EXPECTED_ATTRIBUTES.fetch(operation))
    }.merge(@identity)
    payload["escalation"] = escalation? if operation == "update"

    self.class.send(:verifier).generate(
      payload, expires_in: PREVIEW_TTL, purpose: PREVIEW_PURPOSE
    )
  end
end
