require "digest"
require "json_schemer"
require "pathname"
require "time"
require "hive/provider_routing/policy"
require "hive/runtime_control_plane"

module Hive
  module ProviderRouting
    # First-writer-wins routing policy snapshots in the runtime control plane.
    class PolicyRepository
      SCHEMA = "hive-routing-policy".freeze
      SCHEMA_VERSION = 1
      KIND = "routing-policy".freeze
      MAX_SNAPSHOT_BYTES = 1024 * 1024

      class Error < Hive::Error; end
      class InvalidSnapshot < Error; end

      def initialize(store:)
        @database = store.database
      end

      # Returns the durable winner or nil. A Policy argument is required so a
      # legacy caller can take the structural bypass without opening the point
      # store or loading its schema.
      def fetch(ownership_generation:, subject:, policy:)
        return policy if legacy_policy?(policy)

        key = storage_key(ownership_generation, subject)
        normalize_policy(policy, key: key)
        row = policy_row(key)
        row && parse(row.fetch(:policy_json), expected_key: key)
      end

      # Point-read an already frozen explicit policy when the original
      # configuration candidate is no longer in scope (for example, terminal
      # provider-health acknowledgement).
      def fetch_snapshot(ownership_generation:, subject:)
        key = storage_key(ownership_generation, subject)
        row = policy_row(key)
        row && parse(row.fetch(:policy_json), expected_key: key)
      end

      # Atomically installs the first explicit policy for this ownership point
      # and always returns that winner. A changed candidate for the same point
      # never overwrites the original snapshot.
      def fetch_or_store(ownership_generation:, subject:, policy:)
        return policy if legacy_policy?(policy)

        key = storage_key(ownership_generation, subject)
        candidate = normalize_policy(policy, key: key)
        @database.transaction do |db|
          installation = db[:installations].first&.fetch(:installation_id)
          invalid! unless installation
          current = db[:routing_policies].where(
            installation_id: installation, policy_key: key_digest(key)
          ).first
          next parse(current.fetch(:policy_json), expected_key: key) if current

          payload = dump(snapshot(key, candidate.to_h))
          invalid! if payload.bytesize > MAX_SNAPSHOT_BYTES
          db[:routing_policies].insert(
            installation_id: installation, policy_key: key_digest(key), revision: 0,
            policy_digest: candidate.digest, policy_json: payload,
            updated_at: Time.now.utc.iso8601(6)
          )
          candidate
        end
      rescue Sequel::UniqueConstraintViolation
        fetch_snapshot(ownership_generation: ownership_generation, subject: subject)
      end

      private

      def policy_row(key)
        @database.read do |db|
          installation = db[:installations].first&.fetch(:installation_id)
          next nil unless installation
          db[:routing_policies].where(
            installation_id: installation, policy_key: key_digest(key)
          ).first
        end
      end

      def key_digest(key)
        Digest::SHA256.hexdigest(RuntimeControlPlane::Codec.dump_json(key))
      end

      def snapshot_schema
        @snapshot_schema ||= JSONSchemer.schema(
          Pathname(File.join(Hive::Schemas.schema_dir, "hive-routing-policy.v1.json"))
        )
      end

      def legacy_policy?(policy)
        invalid! unless policy.is_a?(Policy)

        policy.legacy?
      end

      def storage_key(ownership_generation, subject)
        invalid! unless ownership_generation.is_a?(String)
        invalid! unless subject.is_a?(Hash)

        normalized_subject = subject.each_with_object({}) do |(raw_key, value), normalized|
          invalid! unless raw_key.is_a?(String) || raw_key.is_a?(Symbol)

          key = raw_key.to_s
          invalid! if normalized.key?(key)
          normalized[key] = value
        end
        {
          "ownership_generation" => identifier(ownership_generation),
          "subject" => RuntimeControlPlane::Codec.normalize(normalized_subject)
        }.freeze
      rescue Error, RuntimeControlPlane::Error, ArgumentError, TypeError
        invalid!
      end

      def snapshot(key, policy_hash)
        {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "ownership_generation" => key.fetch("ownership_generation"),
          "subject" => key.fetch("subject"),
          "policy" => policy_hash
        }
      end

      def dump(value) = RuntimeControlPlane::Codec.dump_json(value)

      def parse(bytes, expected_key:)
        invalid! unless bytes.is_a?(String) && bytes.bytesize <= MAX_SNAPSHOT_BYTES

        data = RuntimeControlPlane::Codec.load_json(bytes)
        validate_snapshot!(data)
        embedded_key = {
          "ownership_generation" => data.fetch("ownership_generation"),
          "subject" => data.fetch("subject")
        }
        invalid! unless embedded_key == expected_key

        rebuild_policy(data.fetch("policy"))
      rescue InvalidSnapshot
        raise
      rescue RuntimeControlPlane::Error, EncodingError, KeyError, TypeError, ArgumentError
        invalid!
      end

      def identifier(value)
        string = value.to_s
        invalid! unless string.bytesize.between?(1, 128) &&
                        string.valid_encoding? && !string.match?(/[\u0000-\u001f\u007f]/)
        string
      end

      def normalize_policy(policy, key:)
        invalid! unless policy.is_a?(Policy) && policy.explicit?

        payload = snapshot(key, policy.to_h)
        validate_snapshot!(payload)
        rebuild_policy(payload.fetch("policy"))
      end

      def validate_snapshot!(payload)
        invalid! unless snapshot_schema.valid?(payload)
      end

      def rebuild_policy(data)
        accounts = ProviderRouting.deep_freeze(
          ProviderRouting.deep_copy(data.fetch("accounts"))
        )
        invalid! if duplicate_launch_binding?(accounts)

        routes = data.fetch("routes").map do |entry|
          account = accounts[entry.fetch("account")]
          invalid! unless account
          invalid! unless entry.fetch("id") == "#{entry.fetch('account')}/#{entry.fetch('model')}"
          invalid! unless entry.fetch("adapter") == account.fetch("adapter")
          invalid! unless entry.fetch("launch_binding") == account.fetch("launch_binding")
          invalid! unless account.fetch("models").include?(entry.fetch("model"))

          Route.new(
            id: entry.fetch("id"),
            account: entry.fetch("account"),
            adapter: entry.fetch("adapter"),
            launch_binding: entry.fetch("launch_binding"),
            model: entry.fetch("model"),
            effort: entry.fetch("effort"),
            order: entry.fetch("order"),
            capabilities: ProviderRouting.deep_copy(entry.fetch("capabilities")),
            model_routing: nil,
            billing_route: account.fetch("billing_route", "unknown"),
            billing_evidence_source:
              account.fetch("billing_evidence_source", "unavailable")
          )
        end
        invalid! unless routes.map(&:id).uniq.length == routes.length
        invalid! unless routes.map(&:order) == (0...routes.length).to_a
        invalid! unless routes.map(&:account).uniq.sort == accounts.keys.sort

        requirements_data = data.fetch("requirements")
        requirements = Requirements.new(
          context: requirements_data.fetch("context"),
          quality: requirements_data.fetch("quality"),
          tools: requirements_data.fetch("tools"),
          permissions: requirements_data.fetch("permissions")
        )
        pin_data = data.fetch("pin")
        pin = pin_data && Pin.new(
          provider: pin_data.fetch("provider"),
          model: pin_data.fetch("model")
        )
        invalid! if pin && routes.none? do |route|
          route.account == pin.provider && (pin.model.nil? || route.model == pin.model)
        end

        rebuilt = Policy.explicit(
          stage: data.fetch("stage"),
          routes: routes,
          requirements: requirements,
          pin: pin,
          account_policy: accounts
        )
        invalid! unless rebuilt.digest == data.fetch("digest")
        invalid! unless rebuilt.to_h == data
        invalid! if rebuilt.eligible_routes.empty?

        rebuilt
      end

      def duplicate_launch_binding?(accounts)
        accounts.values.group_by do |account|
          [ account.fetch("adapter"), account.fetch("launch_binding") ]
        end.any? { |_identity, entries| entries.length > 1 }
      end

      def invalid!
        raise InvalidSnapshot, "provider routing policy snapshot is invalid"
      end
    end
  end
end
