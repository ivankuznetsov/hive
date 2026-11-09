require "json"
require "time"
require "tmpdir"
require "hive/atomic_file"
require "hive/runtime_identity"
require "hive/runtime_control_plane"
require "hive/daemon/activation_lock"
require "hive/runtime_control_plane/command_schema_installation"
require "hive/runtime_control_plane/command_schema_writer_guard"

module Hive
  module RuntimeControlPlane
    # Setup publishes a complete current database once. Existing storage is
    # validated, never imported, upgraded, or replaced.
    module Installation
      COMMAND_RECEIPT_INSTALLATION_RECORD = "command-receipts-installation.json"

      module_function

      def setup(state_home: Hive::Paths.state_home, install_command_receipts: false,
                rollback_package: CommandSchemaInstallation::PUBLISHED_ROLLBACK_PACKAGE,
                writer_guard: CommandSchemaWriterGuard, web_running: -> { false })
        CommandSchemaInstallation.validate_coordinates!(rollback_package) if install_command_receipts
        Hive::Daemon::ActivationLock.new(hive_home: state_home).synchronize do
          writer_guard.verify!(state_home: state_home, web_running: web_running) if
            install_command_receipts
          path = Hive::Paths.runtime_control_plane_path(state_home)
          database = Database.new(path: path)
          diagnosis = database.diagnostics
          if diagnosis.status == :missing
            File.chmod(0o700, state_home)
            Dir.mktmpdir(".runtime-setup-", state_home) do |temporary|
              candidate = Database.new(path: File.join(temporary, "runtime.sqlite3"))
              begin
                candidate.migrate!
              ensure
                candidate.disconnect
              end
              # The activation lock serializes setup writers. Publish the
              # complete single-link database in one filesystem operation so
              # interruption leaves either missing storage or a usable database.
              if File.exist?(path) || File.symlink?(path)
                raise IntegrityError.new("runtime database appeared during setup",
                                         code: :database_already_present, action: "run hive runtime status")
              end
              File.rename(candidate.path, path)
              Hive::AtomicFile.fsync_directory(state_home)
            end
          else
            raise diagnosis.error unless diagnosis.ok?
          end
          if install_command_receipts
            extension_database = Database.new(path: path)
            begin
              receipts = CommandSchemaInstallation.install!(
                database: extension_database, package_coordinates: rollback_package
              )
            ensure
              extension_database.disconnect
            end
            receipts = record_command_receipt_installation(state_home, receipts)
          end
          result = status(state_home: state_home)
          receipts ? result.merge("command_receipts" => receipts) : result
        ensure
          database&.disconnect
        end
      end

      def command_receipt_installation_record_path(state_home = Hive::Paths.state_home)
        File.join(state_home, COMMAND_RECEIPT_INSTALLATION_RECORD)
      end

      # The receipt extension has no in-database place for rollback provenance
      # (its version ledger is part of the pinned schema digest), so the
      # installing run writes it beside the database. A later already-installed
      # run keeps the original record and reports it back.
      def record_command_receipt_installation(state_home, receipts)
        path = command_receipt_installation_record_path(state_home)
        if receipts.fetch("status") == "installed"
          record = {
            "schema" => "hive-command-receipts-installation.v1",
            "installed_at" => Time.now.utc.iso8601,
            "command_schema_version" => receipts.fetch("version"),
            "command_schema_sha256" => receipts.fetch("schema_sha256"),
            "runtime" => Hive::RuntimeIdentity.new.to_h,
            "rollback" => receipts.fetch("rollback")
          }
          Hive::AtomicFile.write(path, "#{JSON.pretty_generate(record)}\n", mode: 0o600)
        elsif File.file?(path)
          record = JSON.parse(File.read(path))
        end
        receipts.merge("record_path" => path, "record" => record)
      rescue JSON::ParserError, SystemCallError => error
        receipts.merge("record_path" => path, "record" => nil, "record_error" => "#{error.class}: #{error.message}")
      end

      def status(state_home: Hive::Paths.state_home)
        database = Database.new(path: Hive::Paths.runtime_control_plane_path(state_home))
        diagnosis = database.diagnostics
        raise diagnosis.error if diagnosis.error
        identity = database.installation_identity if diagnosis.ok?
        snapshot = database.quiescence_status_snapshot if diagnosis.ok?
        if diagnosis.ok? && (!identity || identity.fetch(:installation_id).to_s.empty?)
          raise IntegrityError.new("runtime installation identity is missing", code: :installation_identity_missing,
                                   action: Database::BACKUP_ACTION)
        end
        { "phase" => diagnosis.ok? ? "active" : "absent",
          "installation_id" => identity && identity.fetch(:installation_id),
          "next_action" => diagnosis.ok? ? nil : "hive setup",
          "lifecycle" => lifecycle_status(snapshot && snapshot[:lifecycle]),
          "database" => Codec.normalize(diagnosis.to_h) }
      ensure
        database&.disconnect
      end

      # Payload paths resolve under the payload root exactly as the store would
      # join them; they are reported, not validated, so an auditor can check
      # containment itself.
      def payloads(state_home: Hive::Paths.state_home)
        database = Database.new(path: Hive::Paths.runtime_control_plane_path(state_home))
        rows = database.payload_references_snapshot
        root = Hive::Paths.runtime_payload_root(state_home)
        { "phase" => rows ? "active" : "absent", "payload_root" => root,
          "payloads" => Array(rows).map do |row|
            row.slice(:payload_id, :kind, :state, :task_id, :attempt_id, :relative_path, :sha256, :bytes)
               .transform_keys(&:to_s).merge("path" => File.expand_path(row.fetch(:relative_path), root))
          end }
      ensure
        database&.disconnect
      end

      def lifecycle_status(row)
        return unless row

        phase = row[:phase].to_s
        {
          "phase" => phase,
          "generation" => row[:generation],
          "revision" => row[:revision],
          "admission_open" => phase == "running"
        }
      end
    end
  end
end
