module HiveLiveAgentProof
  module OpenClawCreatorProof
    class InstallationReceipt
      SCHEMA = "hive-live-agent-installation-receipt".freeze
      SCHEMA_VERSION = 1
      KINDS = %w[candidate_gem openclaw_npm].freeze
      DIGEST_PATTERN = /\A[0-9a-f]{64}\z/.freeze
      INTEGRITY_PATTERN = %r{\Asha512-[A-Za-z0-9+/]+={0,2}\z}.freeze

      def self.write(path:, kind:, artifact_path:, install_root:, executable_path:,
                     package_name:, package_version:, package_integrity: nil,
                     lock_path: nil, package_count: nil)
        root = File.realpath(install_root)
        executable = File.realpath(executable_path)
        artifact = File.realpath(artifact_path)
        lock = lock_path && File.realpath(lock_path)
        payload = {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "kind" => kind,
          "artifact" => file_record(artifact),
          "install_root" => root,
          "executable" => {
            "configured_path" => File.expand_path(executable_path),
            "realpath" => executable,
            "sha256" => Digest::SHA256.file(executable).hexdigest
          },
          "package" => {
            "name" => package_name,
            "version" => package_version
          },
          "lock" => nil
        }
        payload.fetch("package")["integrity"] = package_integrity if package_integrity
        if lock
          payload["lock"] = {
            "path" => lock,
            "sha256" => Digest::SHA256.file(lock).hexdigest,
            "package_count" => Integer(package_count)
          }
        end
        HiveLiveAgentProof.write_json(path, payload)
        payload
      rescue ArgumentError, TypeError => e
        raise Error, "cannot write installation receipt: #{e.message}"
      end

      def self.file_record(path)
        {
          "path" => path,
          "sha256" => Digest::SHA256.file(path).hexdigest,
          "size" => File.size(path)
        }
      end
      private_class_method :file_record

      def initialize(path:, expected_kind:, expected_package_name:,
                     expected_package_version:, expected_package_integrity: nil,
                     expected_lock_sha256: nil, expected_package_count: nil)
        @path = path.to_s
        @expected_kind = expected_kind.to_s
        @expected_package_name = expected_package_name.to_s
        @expected_package_version = expected_package_version.to_s
        @expected_package_integrity = expected_package_integrity
        @expected_lock_sha256 = expected_lock_sha256
        @expected_package_count = expected_package_count
      end

      def call
        receipt_path = regular_absolute_file!(@path, "installation receipt")
        payload = JSON.parse(File.read(receipt_path))
        validate_identity!(payload)
        artifact = validate_file_record!(payload.fetch("artifact"), "artifact")
        install_root = regular_absolute_directory!(
          payload.fetch("install_root"), "installation root"
        )
        executable = validate_executable!(
          payload.fetch("executable"), install_root: install_root
        )
        package = validate_package!(payload.fetch("package"))
        lock = validate_lock!(payload.fetch("lock"), install_root: install_root)

        executable.merge(
          "receipt_path" => receipt_path,
          "receipt_sha256" => Digest::SHA256.file(receipt_path).hexdigest,
          "kind" => @expected_kind,
          "artifact_path" => artifact.fetch("path"),
          "artifact_sha256" => artifact.fetch("sha256"),
          "artifact_size" => artifact.fetch("size"),
          "install_root" => install_root,
          "package" => package,
          "lock" => lock
        )
      rescue JSON::ParserError, KeyError, Errno::ENOENT, Errno::EACCES,
             Errno::ELOOP, Errno::ENOTDIR => e
        raise Error, "installation receipt is invalid: #{e.message}"
      end

      private

      def validate_identity!(payload)
        required = %w[artifact executable install_root kind lock package schema schema_version]
        unless payload.is_a?(Hash) && payload.keys.sort == required
          raise Error, "installation receipt fields are invalid"
        end
        unless payload["schema"] == SCHEMA &&
               payload["schema_version"] == SCHEMA_VERSION &&
               KINDS.include?(payload["kind"]) &&
               payload["kind"] == @expected_kind
          raise Error, "installation receipt identity is invalid"
        end
      end

      def validate_file_record!(record, label)
        required = %w[path sha256 size]
        unless record.is_a?(Hash) && record.keys.sort == required
          raise Error, "#{label} receipt fields are invalid"
        end
        path = regular_absolute_file!(record.fetch("path"), label)
        digest = record.fetch("sha256").to_s
        size = record.fetch("size")
        unless DIGEST_PATTERN.match?(digest) && size.is_a?(Integer) && size.positive?
          raise Error, "#{label} receipt identity is invalid"
        end
        raise Error, "#{label} receipt digest changed" unless
          Digest::SHA256.file(path).hexdigest == digest
        raise Error, "#{label} receipt size changed" unless File.size(path) == size

        { "path" => path, "sha256" => digest, "size" => size }
      end

      def validate_executable!(record, install_root:)
        required = %w[configured_path realpath sha256]
        unless record.is_a?(Hash) && record.keys.sort == required
          raise Error, "executable receipt fields are invalid"
        end
        configured = absolute_path!(record.fetch("configured_path"), "configured executable")
        actual_realpath = File.realpath(configured)
        recorded_realpath = absolute_path!(record.fetch("realpath"), "executable realpath")
        unless actual_realpath == recorded_realpath &&
               File.file?(actual_realpath) && File.executable?(actual_realpath)
          raise Error, "receipt executable is unavailable or changed"
        end
        unless underneath?(actual_realpath, install_root)
          raise Error, "receipt executable escapes its installation root"
        end
        digest = record.fetch("sha256").to_s
        unless DIGEST_PATTERN.match?(digest) &&
               Digest::SHA256.file(actual_realpath).hexdigest == digest
          raise Error, "receipt executable digest changed"
        end

        {
          "configured_path" => configured,
          "realpath" => actual_realpath,
          "sha256" => digest
        }
      end

      def validate_package!(record)
        required = @expected_kind == "openclaw_npm" ?
          %w[integrity name version] : %w[name version]
        unless record.is_a?(Hash) && record.keys.sort == required
          raise Error, "package receipt fields are invalid"
        end
        unless record["name"] == @expected_package_name &&
               record["version"] == @expected_package_version
          raise Error, "package receipt identity is invalid"
        end
        if @expected_kind == "openclaw_npm"
          integrity = record["integrity"].to_s
          unless INTEGRITY_PATTERN.match?(integrity) &&
                 integrity == @expected_package_integrity
            raise Error, "package receipt integrity is invalid"
          end
        end
        record
      end

      def validate_lock!(record, install_root:)
        if @expected_kind == "candidate_gem"
          raise Error, "candidate receipt must not contain an npm lock" unless record.nil?

          return nil
        end
        required = %w[package_count path sha256]
        unless record.is_a?(Hash) && record.keys.sort == required
          raise Error, "npm lock receipt fields are invalid"
        end
        path = regular_absolute_file!(record.fetch("path"), "npm lock")
        raise Error, "npm lock escapes its installation root" unless underneath?(path, install_root)

        digest = record.fetch("sha256").to_s
        count = record.fetch("package_count")
        unless DIGEST_PATTERN.match?(digest) &&
               digest == @expected_lock_sha256 &&
               Digest::SHA256.file(path).hexdigest == digest
          raise Error, "npm lock receipt digest is invalid"
        end
        unless count.is_a?(Integer) && count == @expected_package_count
          raise Error, "npm lock package count is invalid"
        end
        validate_npm_lock!(path, expected_count: count)

        { "path" => path, "sha256" => digest, "package_count" => count }
      end

      def validate_npm_lock!(path, expected_count:)
        lock = JSON.parse(File.read(path))
        packages = lock["packages"]
        root = packages.is_a?(Hash) ? packages[""] : nil
        unless lock["lockfileVersion"] == 3 &&
               root.is_a?(Hash) &&
               root["dependencies"] == { "openclaw" => @expected_package_version } &&
               packages.length - 1 == expected_count
          raise Error, "npm lock root identity is invalid"
        end
        packages.each do |relative, package|
          next if relative.empty?
          unless package.is_a?(Hash) && package["link"] != true &&
                 package["version"].is_a?(String) && !package["version"].empty? &&
                 package["resolved"].to_s.start_with?("https://registry.npmjs.org/") &&
                 INTEGRITY_PATTERN.match?(package["integrity"].to_s)
            raise Error, "npm lock contains a mutable package entry: #{relative}"
          end
        end
        openclaw = packages["node_modules/openclaw"]
        unless openclaw.is_a?(Hash) &&
               openclaw["version"] == @expected_package_version &&
               openclaw["integrity"] == @expected_package_integrity
          raise Error, "npm lock OpenClaw identity is invalid"
        end
      end

      def regular_absolute_file!(value, label)
        path = absolute_path!(value, label)
        stat = File.lstat(path)
        unless stat.file? && !stat.symlink? && File.realpath(path) == path
          raise Error, "#{label} is not a regular canonical file"
        end
        path
      end

      def regular_absolute_directory!(value, label)
        path = absolute_path!(value, label)
        stat = File.lstat(path)
        unless stat.directory? && !stat.symlink? && File.realpath(path) == path
          raise Error, "#{label} is not a regular canonical directory"
        end
        if path == File::SEPARATOR || Pathname.new(path).each_filename.count < 2
          raise Error, "#{label} is too broad"
        end
        path
      end

      def absolute_path!(value, label)
        path = value.to_s
        unless !path.empty? && Pathname.new(path).absolute? &&
               File.expand_path(path) == path
          raise Error, "#{label} must be an absolute canonical path"
        end
        path
      end

      def underneath?(path, root)
        path.start_with?("#{root}#{File::SEPARATOR}")
      end
    end
  end
end
