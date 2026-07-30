require "cgi"
require "rbconfig"
require "hive/atomic_file"
require "hive/refactor_patrol/installed_users_job_schema_migration"

module Hive
  module RefactorPatrol
    # Installs the machine-owned hourly retry for an all-user schema sweep.
    # This boundary is deliberately separate from per-user service installers:
    # it only accepts an already-authorized root-owned candidate and refuses
    # to overwrite units it did not create.
    class InstallWideRetryService
      MANAGED_MARKER = "hive-managed: job-schema-migration-retry/v1".freeze
      SYSTEMD_SERVICE = "hive-job-schema-migration.service".freeze
      SYSTEMD_TIMER = "hive-job-schema-migration.timer".freeze
      LAUNCHD_LABEL = "local.hive-job-schema-migration".freeze
      MAX_UNIT_BYTES = 64 * 1024

      Result = Data.define(:platform, :changed, :active)

      def initialize(
        host_os: RbConfig::CONFIG["host_os"],
        effective_uid: -> { Process.euid },
        trusted_uid: 0,
        systemd_unit_directory: "/etc/systemd/system",
        launchd_unit_directory: "/Library/LaunchDaemons",
        systemctl: "/usr/bin/systemctl",
        launchctl: "/bin/launchctl",
        runner: lambda { |argv|
          system(*argv, out: File::NULL, err: File::NULL)
        },
        lstat: File.method(:lstat),
        realpath: File.method(:realpath),
        reader: File.method(:binread),
        writer: lambda { |path, bytes|
          Hive::AtomicFile.write(path, bytes, mode: 0o644)
          Hive::AtomicFile.fsync_directory(File.dirname(path))
        }
      )
        @host_os = host_os
        @effective_uid = effective_uid
        @trusted_uid = trusted_uid
        @systemd_unit_directory =
          File.expand_path(systemd_unit_directory)
        @launchd_unit_directory =
          File.expand_path(launchd_unit_directory)
        @systemctl = File.expand_path(systemctl)
        @launchctl = File.expand_path(launchctl)
        @runner = runner
        @lstat = lstat
        @realpath = realpath
        @reader = reader
        @writer = writer
      end

      def ensure!(candidate:)
        unless @effective_uid.call == @trusted_uid
          raise Hive::ConfigError,
                "install-wide retry service requires root authority"
        end
        validate_candidate_path!(candidate.path)
        InstalledUsersJobSchemaMigration::CandidateIdentity.verify!(candidate)

        case platform
        when :linux
          ensure_systemd!(candidate.path)
        when :macos
          ensure_launchd!(candidate.path)
        else
          raise Hive::UnavailableError,
                "install-wide retry service is unsupported on this platform"
        end
      end

      private

      def platform
        return :macos if @host_os.match?(/darwin/i)
        return :linux if @host_os.match?(/linux/i)

        :unsupported
      end

      def ensure_systemd!(binary)
        validate_unit_directory!(@systemd_unit_directory)
        service_path =
          File.join(@systemd_unit_directory, SYSTEMD_SERVICE)
        timer_path = File.join(@systemd_unit_directory, SYSTEMD_TIMER)
        units = {
          service_path => render_systemd_service(binary),
          timer_path => systemd_timer_template
        }
        changed = apply_units!(units)
        run_manager!([ @systemctl, "daemon-reload" ])
        run_manager!(
          [ @systemctl, "enable", "--now", SYSTEMD_TIMER ]
        )
        Result.new(platform: "linux", changed: changed, active: true)
      end

      def ensure_launchd!(binary)
        validate_unit_directory!(@launchd_unit_directory)
        path = File.join(
          @launchd_unit_directory, "#{LAUNCHD_LABEL}.plist"
        )
        changed = apply_units!(
          path => render_launchd(binary)
        )
        run_manager!(
          [ @launchctl, "bootout", "system/#{LAUNCHD_LABEL}" ],
          allow_failure: true
        )
        run_manager!([ @launchctl, "bootstrap", "system", path ])
        Result.new(platform: "macos", changed: changed, active: true)
      end

      def apply_units!(units)
        snapshots = units.to_h do |path, expected|
          [ path, inspect_unit(path, expected) ]
        end
        changed = snapshots.any? { |_path, state| state != :exact }
        units.each do |path, bytes|
          next if snapshots.fetch(path) == :exact

          @writer.call(path, bytes)
          verify_written_unit!(path, bytes)
        end
        changed
      end

      def inspect_unit(path, expected)
        stat = @lstat.call(path)
        validate_unit_file!(stat, path)
        bytes = @reader.call(path, MAX_UNIT_BYTES + 1)
        if bytes.bytesize > MAX_UNIT_BYTES
          raise Hive::ConfigError,
                "install-wide retry unit exceeds its size limit: #{path}"
        end
        return :exact if bytes == expected
        return :managed if bytes.include?(MANAGED_MARKER)

        raise Hive::ConfigError,
              "refusing to overwrite unmanaged install-wide retry unit: #{path}"
      rescue Errno::ENOENT
        :missing
      end

      def verify_written_unit!(path, expected)
        stat = @lstat.call(path)
        validate_unit_file!(stat, path)
        unless @reader.call(path, MAX_UNIT_BYTES + 1) == expected
          raise Hive::ConfigError,
                "install-wide retry unit changed while it was installed"
        end
      end

      def validate_unit_directory!(path)
        stat = @lstat.call(path)
        unless stat.directory? && !stat.symlink? &&
               stat.uid == @trusted_uid &&
               (stat.mode & 0o022).zero? &&
               @realpath.call(path) == path
          raise Hive::ConfigError,
                "install-wide retry unit directory is not trusted: #{path}"
        end
      rescue SystemCallError => error
        raise Hive::ConfigError,
              "cannot validate install-wide retry unit directory " \
              "(#{error.class}: #{error.message})"
      end

      def validate_unit_file!(stat, path)
        unless stat.file? && !stat.symlink? && stat.nlink == 1 &&
               stat.uid == @trusted_uid && (stat.mode & 0o022).zero?
          raise Hive::ConfigError,
                "install-wide retry unit is not a trusted regular file: #{path}"
        end
      end

      def validate_candidate_path!(path)
        unless path.match?(%r{\A/[A-Za-z0-9_./+-]+\z})
          raise Hive::ConfigError,
                "install-wide retry candidate path is not unit-safe"
        end
      end

      def run_manager!(argv, allow_failure: false)
        succeeded = @runner.call(argv)
        return true if succeeded
        return false if allow_failure

        raise Hive::UnavailableError,
              "cannot activate install-wide retry service: #{argv.join(' ')}"
      end

      def render_systemd_service(binary)
        systemd_service_template.sub("@HIVE_BINARY@", binary)
      end

      def render_launchd(binary)
        launchd_template.sub("@HIVE_BINARY@", CGI.escapeHTML(binary))
      end

      def systemd_service_template
        File.binread(
          File.expand_path(
            "../../../examples/systemd/hive-job-schema-migration.service",
            __dir__
          )
        )
      end

      def systemd_timer_template
        File.binread(
          File.expand_path(
            "../../../examples/systemd/hive-job-schema-migration.timer",
            __dir__
          )
        )
      end

      def launchd_template
        File.binread(
          File.expand_path(
            "../../../examples/launchd/local.hive-job-schema-migration.plist",
            __dir__
          )
        )
      end
    end
  end
end
