require "timeout"

module HiveLiveAgentProof
  module OpenClawCreatorProof
    class InstallationIdentity
      SCHEMA = "hive-live-agent-installation-receipt".freeze
      SCHEMA_VERSION = 1
      TREE_SCHEMA = "hive-live-agent-installed-tree".freeze
      TREE_SCHEMA_VERSION = 1
      KINDS = %w[candidate_gem openclaw_npm].freeze
      DIGEST_PATTERN = /\A[0-9a-f]{64}\z/.freeze
      INTEGRITY_PATTERN = %r{\Asha512-[A-Za-z0-9+/]+={0,2}\z}.freeze
      TREE_ENTRY_LIMIT = 40_000
      TREE_DIRECTORY_LIMIT = 2_500
      TREE_DEPTH_LIMIT = 16
      TREE_BYTE_LIMIT = 384 * 1024 * 1024
      INTERPRETER_VERSION_LIMIT = 1_024
      INTERPRETER_TIMEOUT = 5
      RECEIPT_BYTE_LIMIT = 1024 * 1024
      MANIFEST_BYTE_LIMIT = 32 * 1024 * 1024
      RECORD_KEYS = %w[
        artifact_path artifact_sha256 artifact_size configured_path install_root
        interpreter kind launcher_interpreter lock package realpath receipt_path
        receipt_sha256 sha256 tree_manifest
      ].freeze

      class Invalid < StandardError; end

      class << self
        def from_receipt!(path:, expected:)
          receipt_path = regular_absolute_file!(path, "installation receipt")
          bytes = bounded_file_bytes!(receipt_path, RECEIPT_BYTE_LIMIT, "installation receipt")
          payload = JSON.parse(bytes)
          identity = retained_projection(
            payload,
            receipt_path: receipt_path,
            receipt_sha256: Digest::SHA256.hexdigest(bytes)
          )
          validate_live!(record: identity, expected: expected)
        rescue JSON::ParserError, KeyError, SystemCallError, Timeout::Error,
               ArgumentError, TypeError => e
          invalid!("installation receipt is invalid: #{e.message}")
        end

        def validate_retained!(record:, expected:)
          normalized_expected = normalize_expected(expected)
          expected_keys = RECORD_KEYS.dup
          expected_keys << "version" if record.is_a?(Hash) && record.key?("version")
          exact_keys!(record, expected_keys, "installation identity")
          invalid!("installation identity kind is invalid") unless
            record["kind"] == normalized_expected.fetch(:kind)
          if record.key?("version")
            invalid!("reported runtime version is invalid") unless
              normalized_expected.fetch(:kind) == "openclaw_npm" &&
              record["version"].is_a?(String) &&
              record["version"].bytesize.between?(1, INTERPRETER_VERSION_LIMIT)
          end

          validate_retained_file_identity!(
            path: record["receipt_path"],
            digest: record["receipt_sha256"],
            label: "installation receipt"
          )
          validate_retained_file_identity!(
            path: record["artifact_path"],
            digest: record["artifact_sha256"],
            size: record["artifact_size"],
            label: "artifact"
          )
          validate_absolute_directory_value!(record["install_root"], "installation root")
          validate_retained_tree_manifest!(record["tree_manifest"], record["install_root"])
          validate_identity_path_separation!(record)
          validate_retained_executable!(
            record.slice("configured_path", "realpath", "sha256"),
            install_root: record["install_root"]
          )
          validate_retained_interpreter!(record["interpreter"], "interpreter", required: true)
          validate_retained_interpreter!(
            record["launcher_interpreter"], "launcher interpreter", required: false
          )
          validate_retained_package!(record["package"], normalized_expected)
          validate_retained_lock!(record["lock"], normalized_expected, record["install_root"])
          record
        rescue KeyError, ArgumentError, TypeError => e
          invalid!("installation identity is invalid: #{e.message}")
        end

        def validate_live!(record:, expected:)
          normalized_expected = normalize_expected(expected)
          validate_retained!(record: record, expected: normalized_expected)
          receipt_path = regular_absolute_file!(
            record.fetch("receipt_path"), "installation receipt"
          )
          receipt_bytes = validated_bounded_file_bytes!(
            path: receipt_path,
            digest: record.fetch("receipt_sha256"),
            max_bytes: RECEIPT_BYTE_LIMIT,
            label: "installation receipt"
          )
          payload = JSON.parse(receipt_bytes)
          projected = retained_projection(
            payload,
            receipt_path: receipt_path,
            receipt_sha256: record.fetch("receipt_sha256")
          )
          retained_projection = record.reject { |key, _value| key == "version" }
          invalid!("installation receipt projection changed") unless
            projected == retained_projection

          validate_live_file!(
            path: record.fetch("artifact_path"),
            digest: record.fetch("artifact_sha256"),
            size: record.fetch("artifact_size"),
            label: "artifact"
          )
          root = regular_absolute_directory!(
            record.fetch("install_root"), "installation root"
          )
          validate_live_tree!(record.fetch("tree_manifest"), install_root: root)
          validate_live_executable!(record, install_root: root)
          validate_live_interpreter!(record.fetch("interpreter"), "interpreter")
          launcher = record.fetch("launcher_interpreter")
          validate_live_interpreter!(launcher, "launcher interpreter") if launcher
          validate_live_lock!(record.fetch("lock"), normalized_expected, install_root: root)
          record
        rescue JSON::ParserError, KeyError, SystemCallError, Timeout::Error,
               ArgumentError, TypeError => e
          invalid!("installation identity is invalid: #{e.message}")
        end

        def expectations_from(record)
          package = record.fetch("package")
          lock = record.fetch("lock")
          {
            kind: record.fetch("kind"),
            package_name: package.fetch("name"),
            package_version: package.fetch("version"),
            package_integrity: package["integrity"],
            lock_sha256: lock&.fetch("sha256"),
            package_count: lock&.fetch("package_count")
          }
        end

        def file_record(path)
          realpath = regular_absolute_file!(path, "file")
          {
            "path" => realpath,
            "sha256" => Digest::SHA256.file(realpath).hexdigest,
            "size" => File.size(realpath)
          }
        end

        def interpreter_record(path)
          configured = absolute_path!(File.expand_path(path), "configured interpreter")
          realpath = File.realpath(configured)
          stat = File.lstat(realpath)
          invalid!("interpreter is not a regular executable") unless
            stat.file? && !stat.symlink? && File.executable?(realpath)
          {
            "configured_path" => configured,
            "realpath" => realpath,
            "sha256" => Digest::SHA256.file(realpath).hexdigest,
            "version" => interpreter_version(realpath)
          }
        end

        def launcher_interpreter_record(executable)
          first_line = File.open(executable, "rb") { |file| file.gets(1_024) }.to_s.scrub.strip
          match = /\A#!(\/\S+)\z/.match(first_line)
          match ? interpreter_record(match[1]) : nil
        end

        def make_tree_read_only!(root)
          tree_paths(root).reverse_each do |entry|
            stat = File.lstat(entry)
            File.chmod(stat.mode & ~0o222, entry) unless stat.symlink?
          end
          File.chmod(File.lstat(root).mode & ~0o222, root)
        end

        def build_tree_manifest(root)
          root = regular_absolute_directory!(root, "installation root")
          entries = []
          directory_count = 0
          total_bytes = 0
          tree_paths(root).each do |path|
            relative = Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
            invalid!("installed tree depth exceeds #{TREE_DEPTH_LIMIT}") if
              Pathname.new(relative).each_filename.count > TREE_DEPTH_LIMIT
            stat = File.lstat(path)
            record = { "path" => relative, "mode" => stat.mode & 0o7777 }
            if stat.file?
              total_bytes += stat.size
              invalid!("installed tree bytes exceed #{TREE_BYTE_LIMIT}") if
                total_bytes > TREE_BYTE_LIMIT
              record.merge!(
                "type" => "file",
                "size" => stat.size,
                "sha256" => Digest::SHA256.file(path).hexdigest
              )
            elsif stat.directory?
              directory_count += 1
              record["type"] = "directory"
            elsif stat.symlink?
              resolved = File.realpath(path)
              invalid!("installed tree symlink escapes its root: #{relative}") unless
                underneath?(resolved, root)
              record.merge!(
                "type" => "symlink",
                "target" => File.readlink(path),
                "resolved_path" =>
                  Pathname.new(resolved).relative_path_from(Pathname.new(root)).to_s
              )
            else
              invalid!("installed tree contains a special entry: #{relative}")
            end
            entries << record
            invalid!("installed tree directory count exceeds #{TREE_DIRECTORY_LIMIT}") if
              directory_count > TREE_DIRECTORY_LIMIT
          end
          {
            "schema" => TREE_SCHEMA,
            "schema_version" => TREE_SCHEMA_VERSION,
            "install_root" => root,
            "entry_count" => entries.length,
            "directory_count" => directory_count,
            "total_file_bytes" => total_bytes,
            "entries" => entries
          }
        end

        def canonical_directory!(path, label)
          regular_absolute_directory!(File.realpath(path), label)
        end

        def underneath?(path, root)
          path.start_with?("#{root}#{File::SEPARATOR}")
        end

        private

        def retained_projection(payload, receipt_path:, receipt_sha256:)
          exact_keys!(
            payload,
            %w[
              artifact executable install_root interpreter kind launcher_interpreter lock
              package schema schema_version tree_manifest
            ],
            "installation receipt"
          )
          invalid!("installation receipt schema is invalid") unless
            payload["schema"] == SCHEMA &&
            payload["schema_version"] == SCHEMA_VERSION &&
            KINDS.include?(payload["kind"])
          artifact = payload.fetch("artifact")
          executable = payload.fetch("executable")
          tree = payload.fetch("tree_manifest")
          exact_keys!(artifact, %w[path sha256 size], "artifact receipt")
          exact_keys!(executable, %w[configured_path realpath sha256], "executable receipt")
          exact_keys!(tree, %w[path sha256 size], "tree-manifest receipt")
          manifest_bytes = bounded_file_bytes!(
            regular_absolute_file!(tree.fetch("path"), "installed tree manifest"),
            MANIFEST_BYTE_LIMIT,
            "installed tree manifest"
          )
          invalid!("installed tree manifest digest changed") unless
            Digest::SHA256.hexdigest(manifest_bytes) == tree.fetch("sha256")
          invalid!("installed tree manifest size changed") unless
            manifest_bytes.bytesize == tree.fetch("size")
          manifest = JSON.parse(manifest_bytes)
          {
            "configured_path" => executable.fetch("configured_path"),
            "realpath" => executable.fetch("realpath"),
            "sha256" => executable.fetch("sha256"),
            "receipt_path" => receipt_path,
            "receipt_sha256" => receipt_sha256,
            "kind" => payload.fetch("kind"),
            "artifact_path" => artifact.fetch("path"),
            "artifact_sha256" => artifact.fetch("sha256"),
            "artifact_size" => artifact.fetch("size"),
            "install_root" => payload.fetch("install_root"),
            "tree_manifest" => tree.merge(
              "entry_count" => manifest.fetch("entry_count"),
              "total_file_bytes" => manifest.fetch("total_file_bytes")
            ),
            "interpreter" => payload.fetch("interpreter"),
            "launcher_interpreter" => payload.fetch("launcher_interpreter"),
            "package" => payload.fetch("package"),
            "lock" => payload.fetch("lock")
          }
        end

        def normalize_expected(expected)
          values = expected.to_h.transform_keys(&:to_sym)
          kind = values.fetch(:kind).to_s
          invalid!("expected installation kind is invalid") unless KINDS.include?(kind)
          {
            kind: kind,
            package_name: values.fetch(:package_name).to_s,
            package_version: values.fetch(:package_version).to_s,
            package_integrity: values[:package_integrity],
            lock_sha256: values[:lock_sha256],
            package_count: values[:package_count]
          }
        end

        def validate_retained_file_identity!(path:, digest:, label:, size: nil)
          absolute_path!(path, label)
          invalid!("#{label} digest is invalid") unless DIGEST_PATTERN.match?(digest.to_s)
          invalid!("#{label} size is invalid") if
            !size.nil? && (!size.is_a?(Integer) || size.negative?)
        end

        def validate_retained_tree_manifest!(record, install_root)
          exact_keys!(
            record,
            %w[entry_count path sha256 size total_file_bytes],
            "installed tree manifest"
          )
          validate_retained_file_identity!(
            path: record["path"], digest: record["sha256"], size: record["size"],
            label: "installed tree manifest"
          )
          invalid!("installed tree manifest counts are invalid") unless
            record["entry_count"].is_a?(Integer) &&
            record["entry_count"].between?(0, TREE_ENTRY_LIMIT) &&
            record["total_file_bytes"].is_a?(Integer) &&
            record["total_file_bytes"].between?(0, TREE_BYTE_LIMIT)
          invalid!("installed tree manifest must be outside its installation root") if
            underneath?(record["path"], install_root)
        end

        def validate_retained_executable!(record, install_root:)
          exact_keys!(record, %w[configured_path realpath sha256], "executable")
          configured = absolute_path!(record["configured_path"], "configured executable")
          realpath = absolute_path!(record["realpath"], "executable realpath")
          invalid!("executable digest is invalid") unless
            DIGEST_PATTERN.match?(record["sha256"].to_s)
          invalid!("executable escapes its installation root") unless
            underneath?(realpath, install_root)
        end

        def validate_identity_path_separation!(record)
          paths = [
            record.fetch("receipt_path"),
            record.fetch("artifact_path"),
            record.fetch("install_root"),
            record.dig("tree_manifest", "path")
          ]
          invalid!("installation identity paths are aliased") unless
            paths.compact.uniq.length == paths.length
        end

        def validate_retained_interpreter!(record, label, required:)
          return if record.nil? && !required

          exact_keys!(record, %w[configured_path realpath sha256 version], label)
          absolute_path!(record["configured_path"], "configured #{label}")
          absolute_path!(record["realpath"], "#{label} realpath")
          invalid!("#{label} digest is invalid") unless
            DIGEST_PATTERN.match?(record["sha256"].to_s)
          version = record["version"]
          invalid!("#{label} version is invalid") unless
            version.is_a?(String) &&
            version.bytesize.between?(1, INTERPRETER_VERSION_LIMIT)
        end

        def validate_retained_package!(record, expected)
          fields = expected.fetch(:kind) == "openclaw_npm" ?
            %w[integrity name version] : %w[name version]
          exact_keys!(record, fields, "package")
          invalid!("package identity is invalid") unless
            record["name"] == expected.fetch(:package_name) &&
            record["version"] == expected.fetch(:package_version)
          return unless expected.fetch(:kind) == "openclaw_npm"

          invalid!("package integrity is invalid") unless
            INTEGRITY_PATTERN.match?(record["integrity"].to_s) &&
            record["integrity"] == expected.fetch(:package_integrity)
        end

        def validate_retained_lock!(record, expected, install_root)
          if expected.fetch(:kind) == "candidate_gem"
            invalid!("candidate installation must not contain an npm lock") unless record.nil?
            return
          end
          exact_keys!(record, %w[package_count path sha256], "npm lock")
          absolute_path!(record["path"], "npm lock")
          invalid!("npm lock escapes its installation root") unless
            underneath?(record["path"], install_root)
          invalid!("npm lock identity is invalid") unless
            record["sha256"] == expected.fetch(:lock_sha256) &&
            DIGEST_PATTERN.match?(record["sha256"].to_s) &&
            record["package_count"] == expected.fetch(:package_count)
        end

        def validate_live_file!(path:, digest:, size:, label:)
          realpath = regular_absolute_file!(path, label)
          invalid!("#{label} digest changed") unless
            Digest::SHA256.file(realpath).hexdigest == digest
          invalid!("#{label} size changed") unless File.size(realpath) == size
        end

        def validate_live_tree!(record, install_root:)
          manifest_bytes = validated_bounded_file_bytes!(
            path: record.fetch("path"),
            digest: record.fetch("sha256"),
            size: record.fetch("size"),
            max_bytes: MANIFEST_BYTE_LIMIT,
            label: "installed tree manifest"
          )
          recorded = JSON.parse(manifest_bytes)
          current = build_tree_manifest(install_root)
          invalid!("installed tree identity changed") unless recorded == current
          invalid!("installed tree entry count changed") unless
            current["entry_count"] == record["entry_count"] &&
            current["total_file_bytes"] == record["total_file_bytes"]
          invalid!("installed tree is not read-only") unless read_only_tree?(current)
        end

        def validate_live_executable!(record, install_root:)
          configured = absolute_path!(record.fetch("configured_path"), "configured executable")
          actual = File.realpath(configured)
          invalid!("receipt executable is unavailable or changed") unless
            actual == record.fetch("realpath") &&
            File.file?(actual) && !File.symlink?(actual) && File.executable?(actual)
          invalid!("receipt executable escapes its installation root") unless
            underneath?(actual, install_root)
          invalid!("receipt executable digest changed") unless
            Digest::SHA256.file(actual).hexdigest == record.fetch("sha256")
        end

        def validate_live_interpreter!(record, label)
          configured = absolute_path!(record.fetch("configured_path"), "configured #{label}")
          actual = File.realpath(configured)
          invalid!("#{label} identity changed") unless
            actual == record.fetch("realpath") &&
            File.file?(actual) && !File.symlink?(actual) && File.executable?(actual) &&
            Digest::SHA256.file(actual).hexdigest == record.fetch("sha256")
          invalid!("#{label} version changed") unless
            interpreter_version(actual) == record.fetch("version")
        end

        def validate_live_lock!(record, expected, install_root:)
          return unless expected.fetch(:kind) == "openclaw_npm"

          lock_bytes = validated_bounded_file_bytes!(
            path: record.fetch("path"),
            digest: record.fetch("sha256"),
            max_bytes: MANIFEST_BYTE_LIMIT,
            label: "npm lock"
          )
          invalid!("npm lock escapes its installation root") unless
            underneath?(record.fetch("path"), install_root)
          lock = JSON.parse(lock_bytes)
          packages = lock["packages"]
          root = packages.is_a?(Hash) ? packages[""] : nil
          invalid!("npm lock root identity is invalid") unless
            lock["lockfileVersion"] == 3 &&
            root.is_a?(Hash) &&
            root["dependencies"] == {
              "openclaw" => expected.fetch(:package_version)
            } &&
            packages.length - 1 == expected.fetch(:package_count)
          packages.each do |relative, package|
            next if relative.empty?
            invalid!("npm lock contains a mutable package entry: #{relative}") unless
              package.is_a?(Hash) && package["link"] != true &&
              package["version"].is_a?(String) && !package["version"].empty? &&
              package["resolved"].to_s.start_with?("https://registry.npmjs.org/") &&
              INTEGRITY_PATTERN.match?(package["integrity"].to_s)
          end
          openclaw = packages["node_modules/openclaw"]
          invalid!("npm lock OpenClaw identity is invalid") unless
            openclaw.is_a?(Hash) &&
            openclaw["version"] == expected.fetch(:package_version) &&
            openclaw["integrity"] == expected.fetch(:package_integrity)
        end

        def read_only_tree?(manifest)
          root_mode = File.lstat(manifest.fetch("install_root")).mode & 0o7777
          (root_mode & 0o222).zero? && manifest.fetch("entries").all? do |entry|
            entry["type"] == "symlink" || (entry.fetch("mode") & 0o222).zero?
          end
        end

        def tree_paths(root)
          paths = []
          pending = Dir.children(root).sort.reverse.map { |name| File.join(root, name) }
          until pending.empty?
            path = pending.pop
            paths << path
            invalid!("installed tree entry count exceeds #{TREE_ENTRY_LIMIT}") if
              paths.length > TREE_ENTRY_LIMIT
            stat = File.lstat(path)
            if stat.directory? && !stat.symlink?
              children = Dir.children(path).sort.reverse.map { |name| File.join(path, name) }
              pending.concat(children)
            end
          end
          paths.sort
        end

        def interpreter_version(realpath)
          output = +""
          status = nil
          Timeout.timeout(INTERPRETER_TIMEOUT) do
            Open3.popen3({}, realpath, "--version", unsetenv_others: true) do |input, stdout,
                                                                            stderr, waiter|
              input.close
              output = stdout.read(INTERPRETER_VERSION_LIMIT + 1)
              error = stderr.read(INTERPRETER_VERSION_LIMIT + 1)
              status = waiter.value
              output = error if output.empty?
            end
          end
          invalid!("interpreter version identity is unavailable") unless
            status&.success? && output.bytesize.between?(1, INTERPRETER_VERSION_LIMIT)
          output.to_s.scrub.lines.first.to_s.strip
        end

        def bounded_file_bytes!(path, max_bytes, label)
          stat = File.lstat(path)
          invalid!("#{label} is not a regular file") unless stat.file? && !stat.symlink?
          invalid!("#{label} exceeds byte budget") if stat.size > max_bytes
          flags = File::RDONLY
          flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
          File.open(path, flags) do |file|
            opened = file.stat
            invalid!("#{label} identity changed while opening") unless
              opened.file? && opened.dev == stat.dev && opened.ino == stat.ino &&
              opened.size <= max_bytes
            bytes = file.read(max_bytes + 1)
            invalid!("#{label} exceeds byte budget") if bytes.bytesize > max_bytes
            invalid!("#{label} changed while reading") unless bytes.bytesize == opened.size
            after = File.lstat(path)
            invalid!("#{label} identity changed after reading") unless
              after.file? && !after.symlink? &&
              after.dev == opened.dev && after.ino == opened.ino &&
              after.size == bytes.bytesize
            bytes
          end
        end

        def validated_bounded_file_bytes!(path:, digest:, max_bytes:, label:, size: nil)
          bytes = bounded_file_bytes!(path, max_bytes, label)
          invalid!("#{label} digest changed") unless
            Digest::SHA256.hexdigest(bytes) == digest
          invalid!("#{label} size changed") if size && bytes.bytesize != size
          bytes
        end

        def regular_absolute_file!(value, label)
          path = absolute_path!(value, label)
          stat = File.lstat(path)
          invalid!("#{label} is not a regular canonical file") unless
            stat.file? && !stat.symlink? && File.realpath(path) == path
          path
        end

        def regular_absolute_directory!(value, label)
          path = absolute_path!(value, label)
          stat = File.lstat(path)
          invalid!("#{label} is not a regular canonical directory") unless
            stat.directory? && !stat.symlink? && File.realpath(path) == path
          invalid!("#{label} is too broad") if
            path == File::SEPARATOR || Pathname.new(path).each_filename.count < 2
          path
        end

        def validate_absolute_directory_value!(value, label)
          path = absolute_path!(value, label)
          invalid!("#{label} is too broad") if
            path == File::SEPARATOR || Pathname.new(path).each_filename.count < 2
          path
        end

        def absolute_path!(value, label)
          path = value.to_s
          invalid!("#{label} must be an absolute canonical path") unless
            !path.empty? && Pathname.new(path).absolute? &&
            File.expand_path(path) == path
          path
        end

        def exact_keys!(value, expected, label)
          invalid!("#{label} fields are invalid") unless
            value.is_a?(Hash) && value.keys.sort == expected.sort
        end

        def invalid!(message)
          raise Invalid, message
        end
      end
    end
  end
end
