require "find"
require "rubygems"
require "hive/invoked_binary"
require "hive/refactor_patrol/installed_users_job_schema_migration"

module Hive
  module RefactorPatrol
    # Privileged all-user migration is available only from an already
    # root-owned installation. This check is intentionally at the command
    # boundary: elevating a Homebrew/user-prefix wrapper and validating it
    # afterward would be too late because that Ruby code already ran as root.
    class AllUsersAuthority
      MAX_RUNTIME_ENTRIES = 100_000

      def initialize(
        effective_uid: -> { Process.euid },
        binary_path: lambda {
          clean = ENV.to_h.reject do |key, _value|
            key == Hive::InvokedBinary::ENV_KEY
          end
          Hive::InvokedBinary.path(env: clean)
        },
        loaded_specs: -> { Gem.loaded_specs.values },
        lstat: File.method(:lstat),
        realpath: File.method(:realpath),
        trusted_uid: 0
      )
        @effective_uid = effective_uid
        @binary_path = binary_path
        @loaded_specs = loaded_specs
        @lstat = lstat
        @realpath = realpath
        @trusted_uid = Integer(trusted_uid)
      end

      def authorize!
        unless @effective_uid.call == @trusted_uid
          raise Hive::ConfigError,
                "install-wide JobStore migration requires root authority"
        end

        binary = @binary_path.call
        unless binary
          raise Hive::UnavailableError,
                "install-wide migration executable is unavailable"
        end
        validate_regular_tree_entry!(binary, label: "Hive executable")

        specs = Array(@loaded_specs.call).freeze
        hive_spec = specs.find do |spec|
          spec.respond_to?(:name) && spec.name == "hive-cli"
        end
        unless hive_spec&.respond_to?(:full_gem_path)
          raise Hive::ConfigError,
                "install-wide migration requires a packaged hive-cli runtime"
        end
        specs.each do |spec|
          next unless spec.respond_to?(:full_gem_path)

          validate_runtime_tree!(spec.full_gem_path)
        end

        InstalledUsersJobSchemaMigration::CandidateIdentity.capture(
          binary, trusted_uid: @trusted_uid
        )
      end

      private

      def validate_runtime_tree!(root)
        canonical = @realpath.call(root)
        validate_directory_entry!(
          canonical, label: "Ruby runtime root"
        )
        count = 0
        Find.find(canonical) do |path|
          count += 1
          if count > MAX_RUNTIME_ENTRIES
            raise Hive::ConfigError,
                  "install-wide migration runtime tree is unbounded"
          end
          stat = @lstat.call(path)
          unless !stat.symlink? && [ "file", "directory" ].include?(stat.ftype) &&
                 stat.uid == @trusted_uid &&
                 (stat.mode & 0o022).zero? &&
                 readable_runtime_entry?(stat)
            raise Hive::ConfigError,
                  "install-wide migration runtime is not root-owned and immutable"
          end
        end
      rescue SystemCallError => error
        raise Hive::ConfigError,
              "cannot validate install-wide migration runtime " \
              "(#{error.class}: #{error.message})"
      end

      def validate_regular_tree_entry!(path, label:)
        canonical = @realpath.call(path)
        stat = @lstat.call(canonical)
        unless stat.file? && !stat.symlink? && stat.nlink == 1 &&
               stat.uid == @trusted_uid &&
               (stat.mode & 0o022).zero? &&
               (stat.mode & 0o005) == 0o005
          raise Hive::ConfigError,
                "#{label} must be a root-owned immutable regular file"
        end
        validate_ancestors!(canonical)
      rescue SystemCallError => error
        raise Hive::ConfigError,
              "cannot validate #{label.downcase} " \
              "(#{error.class}: #{error.message})"
      end

      def validate_directory_entry!(path, label:)
        stat = @lstat.call(path)
        unless stat.directory? && !stat.symlink? &&
               stat.uid == @trusted_uid &&
               (stat.mode & 0o022).zero? &&
               (stat.mode & 0o005) == 0o005
          raise Hive::ConfigError,
                "#{label} must be a root-owned immutable directory"
        end
        validate_ancestors!(path)
      end

      def validate_ancestors!(path)
        candidate = File.dirname(File.expand_path(path))
        loop do
          stat = @lstat.call(candidate)
          unless stat.directory? && !stat.symlink? &&
                 stat.uid == @trusted_uid &&
                 (stat.mode & 0o022).zero? &&
                 (stat.mode & 0o001) == 0o001
            raise Hive::ConfigError,
                  "install-wide migration path has a replaceable ancestor"
          end
          parent = File.dirname(candidate)
          break if parent == candidate

          candidate = parent
        end
      end

      def readable_runtime_entry?(stat)
        if stat.directory?
          (stat.mode & 0o005) == 0o005
        else
          (stat.mode & 0o004) == 0o004
        end
      end
    end
  end
end
