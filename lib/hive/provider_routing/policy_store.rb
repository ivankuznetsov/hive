require "json"
require "json_schemer"
require "pathname"
require "hive/attempts/point_storage"
require "hive/provider_routing/policy"

module Hive
  module ProviderRouting
    # Immutable, point-addressed snapshots of the explicit routing policy that
    # owned one durable subject generation. Admission supplies the surrounding
    # lock order; this store supplies per-cell serialization and first-writer
    # wins persistence. Legacy policies return before the schema or storage
    # adapters are opened, so the no-pool path performs no policy I/O.
    class PolicyStore
      SCHEMA = "hive-routing-policy".freeze
      SCHEMA_VERSION = 1
      KIND = "routing-policy".freeze
      MAX_SNAPSHOT_BYTES = 1024 * 1024

      class InvalidSnapshot < Hive::Attempts::StoreError; end

      attr_reader :root

      def initialize(root:, create_directories: true)
        @root = File.expand_path(root).freeze
        @create_directories = create_directories
        @storage_mutex = Mutex.new
      end

      # Returns the durable winner or nil. A Policy argument is required so a
      # legacy caller can take the structural bypass without opening the point
      # store or loading its schema.
      def fetch(ownership_generation:, subject:, policy:)
        return policy if legacy_policy?(policy)

        key = storage_key(ownership_generation, subject)
        normalize_policy(policy, key: key)
        bytes = storage.read(KIND, key, max_bytes: MAX_SNAPSHOT_BYTES)
        bytes && parse(bytes, expected_key: key)
      end

      # Atomically installs the first explicit policy for this ownership point
      # and always returns that winner. A changed candidate for the same point
      # never overwrites the original snapshot.
      def fetch_or_store(ownership_generation:, subject:, policy:)
        return policy if legacy_policy?(policy)

        key = storage_key(ownership_generation, subject)
        candidate = normalize_policy(policy, key: key)
        storage.synchronize(KIND, key) do
          current = storage.read(KIND, key, max_bytes: MAX_SNAPSHOT_BYTES)
          next parse(current, expected_key: key) if current

          bytes = dump(snapshot(key, candidate.to_h))
          invalid! if bytes.bytesize > MAX_SNAPSHOT_BYTES
          storage.write(
            KIND,
            key,
            bytes,
            expected_bytes: nil,
            max_existing_bytes: MAX_SNAPSHOT_BYTES
          )
          candidate
        end
      end

      private

      def storage
        return @storage if defined?(@storage)

        @storage_mutex.synchronize do
          @storage ||= Hive::Attempts::PointStorage.new(
            root: root,
            label: "provider routing policy store",
            create_directories: @create_directories
          )
        end
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
          "ownership_generation" => Hive::Attempts::StorageKey.string(ownership_generation),
          "subject" => Hive::Attempts::StorageKey.normalize(normalized_subject)
        }.freeze
      rescue Hive::Attempts::StoreError
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

      def dump(value)
        "#{ProviderRouting.canonical_json(value)}\n"
      end

      def parse(bytes, expected_key:)
        invalid! unless bytes.is_a?(String) && bytes.bytesize <= MAX_SNAPSHOT_BYTES

        data = JSON.parse(bytes)
        validate_snapshot!(data)
        embedded_key = {
          "ownership_generation" => data.fetch("ownership_generation"),
          "subject" => data.fetch("subject")
        }
        invalid! unless embedded_key == expected_key

        rebuild_policy(data.fetch("policy"))
      rescue InvalidSnapshot
        raise
      rescue JSON::ParserError, EncodingError, KeyError, TypeError, ArgumentError
        invalid!
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
            model_routing: nil
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
