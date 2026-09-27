require "hive/atomic_file"
require "hive/paths"
require "hive/runtime_control_plane/database"
require "hive/runtime_control_plane/lifecycle_repository"
require "hive/runtime_control_plane/operation_lock"

module Hive
  module RuntimeControlPlane
    # Explicit supervised conversion for the pinned pre-quiescence schema and
    # the exact quiescence-era revisions named below. Ordinary setup/startup
    # continue to reject every non-current schema.
    class QuiescenceUpgrade
      PINNED_V1_SCHEMA_SHA256 = "f237684b17dfd8f7ded175a5e3c7a1b0445c4a7bee109fca4f2f51e498ead0a7".freeze
      QUIESCENCE_SCHEMA_REVISIONS = {
        "484dfc25ef94ab9c06867351308121ba2ce904f1e7f1ef6dc004f45b8d65e479" =>
          "lifecycle-v1",
        "f31651456b27230ef802d910733887fcb5a64b65dead502a2752b1c183f592f3" =>
          "process-custody-v1"
      }.freeze

      def initialize(state_home: Hive::Paths.state_home, timeout_sec: 600,
                     ownership_verifier: -> { false }, clock: -> { Time.now.utc })
        @state_home = File.expand_path(state_home)
        @timeout_sec = Float(timeout_sec)
        raise ArgumentError, "upgrade timeout must be positive and finite" unless
          @timeout_sec.positive? && @timeout_sec.finite?
        @ownership_verifier = ownership_verifier
        @clock = clock
      end

      def call
        database = Database.new(path: Hive::Paths.runtime_control_plane_path(@state_home))
        source = database.quiescence_upgrade_source
        validate_source!(source)
        unless @ownership_verifier.call
          raise Unavailable.new(
            "runtime ownership cannot be verified for the quiescence upgrade",
            code: :ownership_unverifiable,
            action: "stop every Hive service and legacy worker, then retry under supervision"
          )
        end

        OperationLock.new(state_home: @state_home, timeout_sec: @timeout_sec).synchronize do
          database.with_exclusive_writer(role: :migrator, timeout_sec: @timeout_sec) do |authority|
            # Revalidate after both fences are held. An unsupported or reopened
            # source must not invalidate the existing paused proof.
            source = database.quiescence_upgrade_source
            source_kind = validate_source!(source)
            invalidate_proof!
            database.upgrade_quiescence!(
              authority: authority, expected_schema_version: source.fetch(:schema_version),
              expected_fingerprint: source.fetch(:schema_fingerprint),
              preserve_lifecycle: source_kind == :quiescence_revision, now: @clock.call
            )
          end
        end
        lifecycle = LifecycleRepository.new(database: database).current
        {
          "schema" => "hive-runtime-quiescence-upgrade",
          "schema_version" => 1,
          "lifecycle" => {
            "phase" => lifecycle.phase, "generation" => lifecycle.generation,
            "revision" => lifecycle.revision
          }
        }
      ensure
        database&.disconnect
      end

      private

      def validate_source!(source)
        if source[:application_id] == APPLICATION_ID && source[:schema_version] == 1 &&
            source[:schema_fingerprint] == PINNED_V1_SCHEMA_SHA256
          return :pre_quiescence
        end

        revision = QUIESCENCE_SCHEMA_REVISIONS[source[:schema_fingerprint]]
        if source[:application_id] == APPLICATION_ID && source[:schema_version] == 2 && revision
          lifecycle = source[:lifecycle]
          return :quiescence_revision if %w[quiescing paused].include?(lifecycle&.fetch(:phase, nil))

          raise Unavailable.new(
            "quiescence-era runtime must already have admission closed before upgrade",
            code: :quiescence_upgrade_requires_closed_lifecycle,
            action: "quiesce with the matching Hive version before supervised conversion",
            details: { revision: revision, phase: lifecycle&.fetch(:phase, nil) }
          )
        end

        raise MigrationRequired.new(
          "runtime control-plane format is not a supported quiescence upgrade source",
          code: :unsupported_quiescence_upgrade_source, action: Database::MIGRATE_ACTION,
          details: source
        )
      end

      def invalidate_proof!
        path = Hive::Paths.runtime_quiescence_proof_path(@state_home)
        return unless File.exist?(path) || File.symlink?(path)
        status = File.lstat(path)
        unless status.file? && !status.symlink? && status.uid == Process.uid && status.nlink == 1
          raise IntegrityError.new(
            "runtime quiescence proof has unsafe custody", code: :proof_custody_invalid,
            action: Database::BACKUP_ACTION
          )
        end
        File.delete(path)
        Hive::AtomicFile.fsync_directory(File.dirname(path))
      end
    end
  end
end
