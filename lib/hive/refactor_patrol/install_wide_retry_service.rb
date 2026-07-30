require "cgi"
require "rbconfig"
require "hive/atomic_file"
require "hive/refactor_patrol/all_users_authority"
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
      SERVICE_TIMEOUT_SEC = 615
      CLEAN_ENV = "/usr/bin/env".freeze
      SERVICE_PATH =
        "/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin".freeze

      Result = Data.define(:platform, :changed, :active)

      def initialize(
        host_os: RbConfig::CONFIG["host_os"],
        effective_uid: -> { Process.euid },
        trusted_uid: 0,
        systemd_unit_directory: "/etc/systemd/system",
        launchd_unit_directory: "/Library/LaunchDaemons",
        clean_env: CLEAN_ENV,
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
        @clean_env = File.expand_path(clean_env)
        @systemctl = File.expand_path(systemctl)
        @launchctl = File.expand_path(launchctl)
        @runner = runner
        @lstat = lstat
        @realpath = realpath
        @reader = reader
        @writer = writer
      end

      def ensure!(runtime:)
        unless @effective_uid.call == @trusted_uid
          raise Hive::ConfigError,
                "install-wide retry service requires root authority"
        end
        unless runtime.is_a?(AllUsersAuthority::RuntimeIdentity)
          raise Hive::ConfigError,
                "install-wide retry service requires an authorized runtime"
        end
        candidate = runtime.candidate
        validate_candidate_path!(candidate.path)
        [
          runtime.interpreter.path,
          runtime.script.path,
          runtime.manifest.path,
          runtime.gem_home
        ].each { |path| validate_candidate_path!(path) }
        AllUsersAuthority.verify_runtime!(
          runtime, trusted_uid: @trusted_uid, lstat: @lstat
        )

        validate_trusted_executable!(
          @clean_env, label: "clean-environment launcher"
        )
        case platform
        when :linux
          validate_trusted_executable!(
            @systemctl, label: "systemd manager"
          )
          ensure_systemd!(runtime)
        when :macos
          validate_trusted_executable!(
            @launchctl, label: "launchd manager"
          )
          ensure_launchd!(runtime)
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

      def ensure_systemd!(runtime)
        validate_unit_directory!(@systemd_unit_directory)
        service_path =
          File.join(@systemd_unit_directory, SYSTEMD_SERVICE)
        timer_path = File.join(@systemd_unit_directory, SYSTEMD_TIMER)
        units = {
          service_path => render_systemd_service(runtime),
          timer_path => systemd_timer_template
        }
        changed = apply_units!(units)
        run_manager!([ @systemctl, "daemon-reload" ])
        run_manager!(
          [ @systemctl, "enable", "--now", SYSTEMD_TIMER ]
        )
        Result.new(platform: "linux", changed: changed, active: true)
      end

      def ensure_launchd!(runtime)
        validate_unit_directory!(@launchd_unit_directory)
        path = File.join(
          @launchd_unit_directory, "#{LAUNCHD_LABEL}.plist"
        )
        changed = apply_units!(
          path => render_launchd(runtime)
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

      def validate_trusted_executable!(path, label:)
        validate_candidate_path!(path)
        stat = @lstat.call(path)
        parent = File.dirname(path)
        parent_stat = @lstat.call(parent)
        valid = stat.file? && !stat.symlink? && stat.nlink == 1 &&
          stat.uid == @trusted_uid &&
          (stat.mode & 0o022).zero? &&
          (stat.mode & 0o005) == 0o005 &&
          parent_stat.directory? && !parent_stat.symlink? &&
          parent_stat.uid == @trusted_uid &&
          (parent_stat.mode & 0o022).zero? &&
          @realpath.call(path) == path &&
          @realpath.call(parent) == parent
        return true if valid

        raise Hive::ConfigError,
              "install-wide retry #{label} is not trusted: #{path}"
      rescue SystemCallError, IOError => error
        raise Hive::ConfigError,
              "cannot validate install-wide retry #{label} " \
              "(#{error.class}: #{error.message})"
      end

      def run_manager!(argv, allow_failure: false)
        succeeded = @runner.call(argv)
        return true if succeeded
        return false if allow_failure

        raise Hive::UnavailableError,
              "cannot activate install-wide retry service: #{argv.join(' ')}"
      end

      def render_systemd_service(runtime)
        render_runtime_template(systemd_service_template, runtime)
      end

      def render_launchd(runtime)
        values = runtime_template_values(runtime).transform_values do |value|
          CGI.escapeHTML(value)
        end
        render_values(launchd_template, values)
      end

      def render_runtime_template(template, runtime)
        render_values(template, runtime_template_values(runtime))
      end

      def runtime_template_values(runtime)
        {
          "@CLEAN_ENV@" => @clean_env,
          "@GEM_HOME@" => runtime.gem_home,
          "@HIVE_BINARY@" => runtime.candidate.path,
          "@MANIFEST@" => runtime.manifest.path,
          "@RUBY@" => runtime.interpreter.path,
          "@SCRIPT@" => runtime.script.path,
          "@SERVICE_PATH@" => SERVICE_PATH,
          "@TIMEOUT_SEC@" => SERVICE_TIMEOUT_SEC.to_s
        }
      end

      def render_values(template, values)
        values.reduce(template) do |bytes, (placeholder, value)|
          bytes.gsub(placeholder, value)
        end
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
