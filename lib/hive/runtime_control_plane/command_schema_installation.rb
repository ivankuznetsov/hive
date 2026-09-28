# frozen_string_literal: true

require "uri"
require "hive/runtime_control_plane"
require "hive/runtime_control_plane/command_schema"
require "hive/runtime_control_plane/command_migrations/002_add_command_receipts"

module Hive
  module RuntimeControlPlane
    module CommandSchemaInstallation
      PUBLISHED_ROLLBACK_PACKAGE = {
        version: nil,
        location: nil,
        sha256: nil
      }.freeze

      module_function

      def validate_coordinates!(coordinates = PUBLISHED_ROLLBACK_PACKAGE)
        version = coordinates && (coordinates[:version] || coordinates["version"])
        location = coordinates && (coordinates[:location] || coordinates["location"])
        sha256 = coordinates && (coordinates[:sha256] || coordinates["sha256"])
        uri = URI.parse(location.to_s)
        valid = !version.to_s.empty? && version.to_s !~ /pending|placeholder/i &&
          uri.is_a?(URI::HTTPS) && !uri.host.to_s.empty? &&
          sha256.to_s.match?(/\A[0-9a-f]{64}\z/i)
        return coordinates if valid

        raise Hive::ConfigError,
              "this build ships no published rollback package; run `hive setup` " \
              "(or `hive setup --yes`) without --install-command-receipts for " \
              "base-only installation or refresh until publication is complete"
      rescue URI::InvalidURIError
        raise Hive::ConfigError,
              "this build ships no published rollback package; run `hive setup` " \
              "(or `hive setup --yes`) without --install-command-receipts for " \
              "base-only installation or refresh until publication is complete"
      end

      def install!(database:, package_coordinates: PUBLISHED_ROLLBACK_PACKAGE)
        validate_coordinates!(package_coordinates)
        diagnosis = database.diagnostics
        raise diagnosis.error unless diagnosis.ok?
        return { "status" => "already_installed", "version" => CommandSchema::VERSION } if
          CommandSchema.installed?(database)

        database.read do |connection|
          unless CommandSchema.absent?(connection)
            raise MigrationRequired.new(
              "runtime control-plane command receipt extension is partial or unknown",
              code: :partial_command_schema, action: Database::MIGRATE_ACTION
            )
          end
        end

        database.transaction(track_mutation: false) do |connection|
          CommandMigrations::AddCommandReceipts002.apply(
            connection, checksum: CommandSchema::EXPECTED_SCHEMA_SHA256
          )
          unless CommandSchema.exact?(connection)
            raise IntegrityError.new(
              "installed command receipt extension does not match its manifest",
              code: :command_schema_mismatch, action: Database::BACKUP_ACTION,
              details: { actual_sha256: CommandSchema.checksum(connection) }
            )
          end
        end
        { "status" => "installed", "version" => CommandSchema::VERSION }
      end
    end
  end
end
