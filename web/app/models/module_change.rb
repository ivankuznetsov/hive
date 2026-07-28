require "hive/module_package/permission_atoms"

class ModuleChange
  PREVIEW_PURPOSE = "hive-web-module-lifecycle".freeze
  PERMISSION_PURPOSE = "hive-web-module-permission".freeze
  PREVIEW_TTL = 10.minutes
  PREVIEW_SCHEMA_VERSION = 1
  OPERATIONS = %w[install update enable disable uninstall].freeze
  PERMISSION_CONTEXT_KEYS = %w[
    module module_receipt operation permission_digest project
  ].freeze
  PREVIEW_PAYLOAD_KEYS = %w[
    choices module module_receipt name operation permission_digest project
    required_permission_atoms schema_version source
  ].freeze

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

    def apply!(operation:, token:, consent:, permission_atom_tokens: [])
      operation = operation!(operation)
      require_consent!(operation, consent)
      receipt = verify_preview!(token, operation)
      verify_permission_consents!(receipt, permission_atom_tokens)
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
      unless payload.is_a?(Hash) && payload.keys.sort == PREVIEW_PAYLOAD_KEYS.sort &&
             payload["schema_version"] == PREVIEW_SCHEMA_VERSION &&
             payload["operation"] == operation &&
             payload["project"].is_a?(String) && !payload["project"].empty? &&
             payload["module"].is_a?(String) && !payload["module"].empty? &&
             payload["module_receipt"].is_a?(String) &&
             payload["required_permission_atoms"].is_a?(Array) &&
             payload["choices"].is_a?(Hash)
        raise Hive::Error, "module preview does not match this action; review it again"
      end
      payload
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      raise Hive::Error, "module preview expired or changed; review it again before applying"
    end

    def verify_permission_consents!(receipt, tokens)
      expected = Array(receipt["required_permission_atoms"]).map do |atom|
        Hive::ModulePackage::PermissionAtoms.canonicalize(atom)
      end
      expected_keys = expected.map { |atom| permission_atom_key(atom) }
      raise_permission_consent_error! unless expected_keys.uniq.length == expected_keys.length
      supplied_tokens = Array(tokens).map(&:to_s)
      invalid = supplied_tokens.any?(&:empty?) ||
        supplied_tokens.uniq.length != supplied_tokens.length
      raise_permission_consent_error! if invalid

      supplied = supplied_tokens.map do |permission_token|
        verify_permission_token!(permission_token, receipt)
      end
      expected_keys = expected_keys.sort
      supplied_keys = supplied.map { |atom| permission_atom_key(atom) }.sort
      raise_permission_consent_error! unless supplied_keys == expected_keys
      true
    rescue Hive::ConfigError
      raise_permission_consent_error!
    end

    def verify_permission_token!(token, receipt)
      payload = verifier.verify(token, purpose: PERMISSION_PURPOSE)
      expected_context = permission_context(receipt)
      expected_keys = (PERMISSION_CONTEXT_KEYS + %w[category value]).sort
      unless payload.is_a?(Hash) && payload.keys.sort == expected_keys &&
             expected_context.all? { |key, value| payload[key] == value }
        raise_permission_consent_error!
      end
      Hive::ModulePackage::PermissionAtoms.canonicalize(
        payload.slice("category", "value")
      )
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      raise_permission_consent_error!
    end

    def permission_context(receipt)
      PERMISSION_CONTEXT_KEYS.to_h do |key|
        [ key, receipt.fetch(key) ]
      end
    rescue KeyError
      raise_permission_consent_error!
    end

    def permission_atom_key(atom)
      Hive::ModulePackage::PermissionAtoms.canonical_key(atom)
    end

    def raise_permission_consent_error!
      raise Hive::Error, "confirm every exact separately disclosed module permission"
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

  def permission_atoms
    proposal = details["proposed"]
    return [].freeze unless proposal

    Hive::ModulePackage::PermissionAtoms.expand(proposal.fetch("grants"))
  end

  def permission_consents
    @permission_consents ||= permission_atoms.map do |atom|
      payload = permission_context.merge(atom)
      atom.merge(
        "token" => self.class.send(:verifier).generate(
          payload, expires_in: PREVIEW_TTL, purpose: PERMISSION_PURPOSE
        )
      ).freeze
    end.freeze
  end

  def token
    @token ||= begin
      payload = {
        "schema_version" => PREVIEW_SCHEMA_VERSION,
        "operation" => operation, "project" => project.name,
        "module_receipt" => details.fetch("preview_receipt"),
        "module" => details.fetch("name"),
        "permission_digest" => permission_digest,
        "required_permission_atoms" => permission_atoms
      }.merge(@identity)
      self.class.send(:verifier).generate(
        payload, expires_in: PREVIEW_TTL, purpose: PREVIEW_PURPOSE
      )
    end
  end

  private

  def permission_context
    {
      "operation" => operation, "project" => project.name,
      "module" => details.fetch("name"),
      "module_receipt" => details.fetch("preview_receipt"),
      "permission_digest" => permission_digest
    }
  end

  def permission_digest
    proposal = details["proposed"]
    return nil unless proposal

    value = proposal["permission_digest"]
    unless Hive::ModulePackage::Manifest::SHA256.match?(value.to_s)
      raise Hive::Error, "module preview permission digest is missing or malformed"
    end
    value
  end
end
