require "tmpdir"
require "hive/runtime_control_plane"
require "hive/daemon/activation_lock"

module Hive
  module RuntimeControlPlane
    # Setup publishes a complete current database once. Existing storage is
    # validated, never imported, upgraded, or replaced.
    module Installation
      module_function

      def setup(state_home: Hive::Paths.state_home)
        Hive::Daemon::ActivationLock.new(hive_home: state_home).synchronize do
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
          status(state_home: state_home)
        ensure
          database&.disconnect
        end
      end

      def status(state_home: Hive::Paths.state_home)
        database = Database.new(path: Hive::Paths.runtime_control_plane_path(state_home))
        diagnosis = database.diagnostics
        raise diagnosis.error if diagnosis.error
        identity = database.installation_identity if diagnosis.ok?
        if diagnosis.ok? && (!identity || identity.fetch(:installation_id).to_s.empty?)
          raise IntegrityError.new("runtime installation identity is missing", code: :installation_identity_missing,
                                   action: Database::BACKUP_ACTION)
        end
        { "phase" => diagnosis.ok? ? "active" : "absent",
          "installation_id" => identity && identity.fetch(:installation_id),
          "next_action" => diagnosis.ok? ? nil : "hive setup",
          "database" => Codec.normalize(diagnosis.to_h) }
      ensure
        database&.disconnect
      end
    end
  end
end
