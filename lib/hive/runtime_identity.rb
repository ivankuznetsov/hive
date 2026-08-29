require "hive/version"
require "hive/canonical_json"

module Hive
  # Validated identity projection for the Hive runtime reached through the
  # active `hive` command. Release metadata stays suitable for package-manager
  # version checks while dogfood deployments add exact build provenance.
  class RuntimeIdentity
    CHANNEL_ENV = "HIVE_RUNTIME_CHANNEL"
    BUILD_SHA_ENV = "HIVE_RUNTIME_BUILD_SHA"
    DEPLOYMENT_ID_ENV = "HIVE_RUNTIME_DEPLOYMENT_ID"
    CHANNELS = %w[release dogfood].freeze
    SHA_PATTERN = /\A[0-9a-f]{40}\z/
    DEPLOYMENT_ID_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}\z/
    VERSION_PATTERN = /\A[0-9A-Za-z][0-9A-Za-z.+-]{0,127}\z/
    FIELDS = %w[channel release_version display_version build_sha deployment_id].freeze
    SOURCE_FIELDS = %w[channel release_version build_sha].freeze

    def self.unknown(release_version: Hive::VERSION)
      new(
        environment: { CHANNEL_ENV => "unknown" },
        release_version: release_version
      ).to_h
    end

    def self.source_digest(identity = new.to_h)
      Hive::CanonicalJSON.digest(identity.slice(*SOURCE_FIELDS))
    end

    # Accept an identity reported by another Hive process only when its closed
    # shape and derived display value agree. Callers use nil as fail-closed
    # evidence and project #unknown instead.
    def self.parse(value)
      return unless value.is_a?(Hash) && value.keys.all? { |key| key.is_a?(String) }
      return unless value.keys.sort == FIELDS.sort
      return unless valid_version_string?(value["release_version"])

      expected = new(
        environment: {
          CHANNEL_ENV => value["channel"],
          BUILD_SHA_ENV => value["build_sha"],
          DEPLOYMENT_ID_ENV => value["deployment_id"]
        },
        release_version: value["release_version"]
      ).to_h
      return unless value == expected

      FIELDS.to_h { |field| [ field, value[field] ] }
    end

    def self.valid_version_string?(value)
      value.is_a?(String) && value.valid_encoding? && VERSION_PATTERN.match?(value)
    end

    private_class_method :valid_version_string?

    def initialize(environment: ENV, release_version: Hive::VERSION)
      @environment = environment
      @release_version = release_version.to_s
    end

    def to_h
      requested_channel = channel
      resolved_sha = requested_channel == "dogfood" ? build_sha : nil
      resolved_deployment_id = requested_channel == "dogfood" ? deployment_id : nil
      resolved_channel = resolve_channel(requested_channel, resolved_sha, resolved_deployment_id)
      dogfood = resolved_channel == "dogfood"
      {
        "channel" => resolved_channel,
        "release_version" => @release_version,
        "display_version" => display_version(resolved_channel, resolved_sha),
        "build_sha" => dogfood ? resolved_sha : nil,
        "deployment_id" => dogfood ? resolved_deployment_id : nil
      }
    end

    private

    def channel
      value = @environment[CHANNEL_ENV].to_s
      return "release" if value.empty?
      return value if CHANNELS.include?(value)

      "unknown"
    end

    def build_sha
      value = @environment[BUILD_SHA_ENV].to_s
      value.valid_encoding? && SHA_PATTERN.match?(value) ? value : nil
    end

    def deployment_id
      value = @environment[DEPLOYMENT_ID_ENV].to_s
      value.valid_encoding? && DEPLOYMENT_ID_PATTERN.match?(value) ? value : nil
    end

    def resolve_channel(requested_channel, resolved_sha, resolved_deployment_id)
      return requested_channel unless requested_channel == "dogfood"
      return "dogfood" if resolved_sha && resolved_deployment_id

      "unknown"
    end

    def display_version(resolved_channel, resolved_sha)
      return @release_version if resolved_channel == "release"
      return "#{@release_version}+unknown" if resolved_channel == "unknown"

      "#{@release_version}+dogfood.#{resolved_sha[0, 9]}"
    end
  end
end
