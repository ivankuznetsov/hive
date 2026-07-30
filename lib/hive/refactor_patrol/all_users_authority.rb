require "find"
require "json"
require "rubygems"
require "rbconfig"
require "digest"
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
      MAX_MANIFEST_BYTES = 32 * 1024
      BUILTIN_FEATURES = %w[
        complex.so enumerator.so fiber.so rational.so ruby2_keywords.rb
        thread.rb
      ].freeze
      LAUNCHER_MARKER = "HIVE_ROOT_RUNTIME_LAUNCHER".freeze
      MANIFEST_ENV = "HIVE_ROOT_RUNTIME_MANIFEST".freeze
      RuntimeFile = Data.define(
        :path, :dev, :ino, :size, :mode, :uid, :gid, :mtime, :ctime,
        :sha256
      )
      RuntimeIdentity = Data.define(
        :candidate, :interpreter, :script, :manifest, :gem_home
      )

      def self.verify_runtime!(
        runtime,
        trusted_uid: 0,
        lstat: File.method(:lstat)
      )
        unless runtime.is_a?(RuntimeIdentity)
          raise Hive::ConfigError,
                "install-wide runtime identity is malformed"
        end
        InstalledUsersJobSchemaMigration::CandidateIdentity.verify!(
          runtime.candidate
        )
        [ runtime.interpreter, runtime.script, runtime.manifest ].each do |entry|
          stat = lstat.call(entry.path)
          stable = stat.file? && !stat.symlink? && stat.nlink == 1 &&
            stat.uid == Integer(trusted_uid) &&
            stat.dev == entry.dev && stat.ino == entry.ino &&
            stat.size == entry.size &&
            (stat.mode & 0o777) == entry.mode &&
            stat.mtime.to_f == entry.mtime &&
            stat.ctime.to_f == entry.ctime &&
            Digest::SHA256.file(entry.path).hexdigest == entry.sha256
          unless stable
            raise Hive::ConfigError,
                  "install-wide runtime changed after authorization"
          end
        end
        true
      rescue SystemCallError, IOError => error
        raise Hive::ConfigError,
              "cannot revalidate install-wide runtime " \
              "(#{error.class}: #{error.message})"
      end

      def initialize(
        effective_uid: -> { Process.euid },
        binary_path: lambda {
          clean = ENV.to_h.reject do |key, _value|
            key == Hive::InvokedBinary::ENV_KEY
          end
          Hive::InvokedBinary.path(env: clean)
        },
        loaded_specs: -> { Gem.loaded_specs.values },
        loaded_features: -> { $LOADED_FEATURES.dup },
        interpreter_path: -> { RbConfig.ruby },
        program_path: -> { File.expand_path($PROGRAM_NAME) },
        environment: ENV,
        lstat: File.method(:lstat),
        realpath: File.method(:realpath),
        trusted_uid: 0,
        require_launcher_marker: true
      )
        @effective_uid = effective_uid
        @binary_path = binary_path
        @loaded_specs = loaded_specs
        @loaded_features = loaded_features
        @interpreter_path = interpreter_path
        @program_path = program_path
        @environment = environment
        @lstat = lstat
        @realpath = realpath
        @trusted_uid = Integer(trusted_uid)
        @require_launcher_marker = require_launcher_marker == true
      end

      def authorize!
        unless @effective_uid.call == @trusted_uid
          raise Hive::ConfigError,
                "install-wide JobStore migration requires root authority"
        end
        validate_launcher_marker!

        binary = @binary_path.call
        unless binary
          raise Hive::UnavailableError,
                "install-wide migration executable is unavailable"
        end
        launcher = capture_runtime_file!(
          binary, label: "Hive executable", executable: true
        )
        interpreter = capture_runtime_file!(
          @interpreter_path.call,
          label: "Ruby interpreter",
          executable: true
        )
        script = capture_runtime_file!(
          @program_path.call,
          label: "Hive Ruby entrypoint",
          executable: false
        )
        manifest_path = @environment[MANIFEST_ENV].to_s
        manifest = capture_runtime_file!(
          manifest_path,
          label: "Hive root runtime manifest",
          executable: false
        )
        manifest_payload = read_manifest(manifest.path)

        specs = Array(@loaded_specs.call).freeze
        hive_spec = specs.find do |spec|
          spec.respond_to?(:name) && spec.name == "hive-cli"
        end
        unless hive_spec&.respond_to?(:full_gem_path)
          raise Hive::ConfigError,
                "install-wide migration requires a packaged hive-cli runtime"
        end
        runtime_entries = 0
        specs.each do |spec|
          next unless spec.respond_to?(:full_gem_path)

          runtime_entries = validate_runtime_tree!(
            spec.full_gem_path, count: runtime_entries
          )
        end
        Array(@loaded_features.call).each do |path|
          feature = path.to_s
          next if BUILTIN_FEATURES.include?(feature)
          unless !feature.empty? &&
                 File.absolute_path(feature) == feature
            raise Hive::ConfigError,
                  "install-wide migration loaded feature path is not absolute"
          end

          capture_runtime_file!(
            feature, label: "loaded Ruby feature", executable: false
          )
        rescue ArgumentError
          raise Hive::ConfigError,
                "install-wide migration loaded feature path is malformed"
        end

        candidate =
          InstalledUsersJobSchemaMigration::CandidateIdentity.capture(
            launcher.path, trusted_uid: @trusted_uid
          )
        validate_manifest!(
          manifest_payload,
          launcher: launcher,
          interpreter: interpreter,
          script: script,
          hive_spec: hive_spec
        )
        RuntimeIdentity.new(
          candidate: candidate,
          interpreter: interpreter,
          script: script,
          manifest: manifest,
          gem_home: manifest_payload.fetch("gem_home")
        )
      end

      private

      def validate_launcher_marker!
        return unless @require_launcher_marker
        return if @environment[LAUNCHER_MARKER] == "1" &&
                  !@environment[MANIFEST_ENV].to_s.empty?

        raise Hive::ConfigError,
              "install-wide migration requires the root-owned Hive launcher"
      end

      def capture_runtime_file!(path, label:, executable:)
        canonical = @realpath.call(path)
        stat = @lstat.call(canonical)
        executable_mode = !executable || (stat.mode & 0o005) == 0o005
        unless stat.file? && !stat.symlink? && stat.nlink == 1 &&
               stat.uid == @trusted_uid &&
               (stat.mode & 0o022).zero? &&
               (stat.mode & 0o004) == 0o004 &&
               executable_mode
          raise Hive::ConfigError,
                "#{label} must be a root-owned immutable regular file"
        end
        validate_ancestors!(canonical)
        RuntimeFile.new(
          path: canonical,
          dev: stat.dev,
          ino: stat.ino,
          size: stat.size,
          mode: stat.mode & 0o777,
          uid: stat.uid,
          gid: stat.gid,
          mtime: stat.mtime.to_f,
          ctime: stat.ctime.to_f,
          sha256: Digest::SHA256.file(canonical).hexdigest
        ).freeze
      rescue SystemCallError, IOError => error
        raise Hive::ConfigError,
              "cannot validate #{label.downcase} " \
              "(#{error.class}: #{error.message})"
      end

      def read_manifest(path)
        bytes = File.binread(path, MAX_MANIFEST_BYTES + 1)
        if bytes.bytesize > MAX_MANIFEST_BYTES
          raise Hive::ConfigError,
                "Hive root runtime manifest exceeds its size limit"
        end

        JSON.parse(bytes)
      rescue JSON::ParserError => error
        raise Hive::ConfigError,
              "Hive root runtime manifest is malformed " \
              "(#{error.message})"
      end

      def validate_manifest!(payload, launcher:, interpreter:, script:,
                             hive_spec:)
        expected_keys = %w[
          gem_home launcher ruby schema schema_version script
        ]
        gem_home = File.expand_path(payload.fetch("gem_home"))
        valid = payload.is_a?(Hash) &&
          payload.keys.sort == expected_keys &&
          payload["schema"] == "hive-root-runtime" &&
          payload["schema_version"] == 1 &&
          File.expand_path(payload["launcher"]) == launcher.path &&
          File.expand_path(payload["ruby"]) == interpreter.path &&
          File.expand_path(payload["script"]) == script.path &&
          File.expand_path(hive_spec.full_gem_path).start_with?(
            "#{gem_home}#{File::SEPARATOR}"
          )
        unless valid
          raise Hive::ConfigError,
                "Hive root runtime manifest does not match the loaded runtime"
        end
        validate_directory_entry!(
          @realpath.call(gem_home), label: "Hive root gem home"
        )
      rescue KeyError, ArgumentError, TypeError
        raise Hive::ConfigError,
              "Hive root runtime manifest is malformed"
      end

      def validate_runtime_tree!(root, count:)
        canonical = @realpath.call(root)
        validate_directory_entry!(
          canonical, label: "Ruby runtime root"
        )
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
        count
      rescue SystemCallError => error
        raise Hive::ConfigError,
              "cannot validate install-wide migration runtime " \
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
