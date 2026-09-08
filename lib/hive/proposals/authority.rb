require "time"
require "hive/proposals"
require "hive/proposals/configuration_row"

module Hive
  module Proposals
    class Authority
      CAPABILITIES = AUTHORITY_CAPABILITIES
      KINDS = AUTHORITY_KINDS
      ROW_REQUIRED = AUTHORITY_REQUIRED_KEYS
      ROW_OPTIONAL = AUTHORITY_OPTIONAL_KEYS
      RECEIPT_KEYS = %w[authority_id capability policy_fingerprint issued_at].freeze

      def initialize(config, clock: -> { Time.now.utc })
        @config = Proposals.stringify(config.fetch("proposals", config))
        @clock = clock
      end

      def fingerprint(identity)
        Proposals.digest(normalized_row!(identity))
      end

      def authorize!(identity:, capability:, expected_policy_fingerprint:, receipt: nil)
        identity = Proposals.label!(identity, label: "proposal authority identity")
        capability = capability.to_s
        raise Unauthorized, "unknown proposal lifecycle capability" unless CAPABILITIES.include?(capability)

        row = normalized_row!(identity)
        current_fingerprint = Proposals.digest(row)
        expected = Proposals.digest!(
          expected_policy_fingerprint, label: "proposal authority policy fingerprint"
        )
        unless expected == current_fingerprint
          raise StaleObservation, "proposal authority policy changed; refresh authority observation"
        end
        raise Unauthorized, "proposal authority is revoked" if row.fetch("revoked")
        unless row.fetch("capabilities").include?(capability)
          raise Unauthorized, "proposal authority lacks #{capability} capability"
        end
        enforce_validity!(row)
        validate_policy_receipt!(receipt, identity:, capability:, fingerprint: current_fingerprint) if
          row.fetch("kind") == "policy"
        Proposals.deep_copy_freeze(
          "id" => identity, "kind" => row.fetch("kind"),
          "policy_fingerprint" => current_fingerprint
        )
      end

      private

      def normalized_row!(identity)
        identity = Proposals.label!(identity, label: "proposal authority identity")
        raw = @config.fetch("authorities", {}).fetch(identity, nil)
        raise Unauthorized, "proposal lifecycle authority is not configured" unless raw

        ConfigurationRow.authority!(raw)
      end

      def enforce_validity!(row)
        now = @clock.call.utc
        if row["valid_from"] && now < Time.iso8601(row["valid_from"])
          raise Unauthorized, "proposal authority is not yet valid"
        end
        if row["valid_until"] && now >= Time.iso8601(row["valid_until"])
          raise Unauthorized, "proposal authority has expired"
        end
      end

      def validate_policy_receipt!(receipt, identity:, capability:, fingerprint:)
        data = Proposals.closed_hash!(
          receipt, required: RECEIPT_KEYS, label: "proposal policy receipt"
        )
        unless data["authority_id"] == identity && data["capability"] == capability &&
               data["policy_fingerprint"] == fingerprint
          raise Unauthorized, "proposal policy receipt does not match authority"
        end
        issued_at = Time.iso8601(
          Proposals.timestamp!(data["issued_at"], label: "proposal policy receipt issued_at")
        )
        if issued_at > @clock.call.utc + 60
          raise Unauthorized, "proposal policy receipt is future-dated"
        end
      rescue InvalidRecord, ArgumentError => error
        raise Unauthorized, "proposal policy receipt is invalid: #{error.class}"
      end
    end
  end
end
