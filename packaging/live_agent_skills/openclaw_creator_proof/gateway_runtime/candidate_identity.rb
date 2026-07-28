module HiveLiveAgentProof
  module OpenClawCreatorGatewayRuntime
    class CandidateIdentity
      MAX_TREE_ENTRIES = 40_000
      MAX_TREE_DEPTH = 16
      VERSION_LIMIT = 1_024

      def initialize(candidate:, expected_digest:, installation_identity:)
        @candidate = candidate
        @expected_digest = expected_digest
        @installation_identity = installation_identity
      end

      def valid?
        return basic_candidate_valid? unless @installation_identity

        receipt = verified_receipt
        manifest = verified_manifest(receipt)
        root = receipt.fetch("install_root")
        return false unless current_tree(root) == manifest
        return false unless read_only_tree?(root, manifest)
        return false unless interpreter_valid?(receipt.fetch("interpreter"))
        return false unless launcher_interpreter_valid?(receipt["launcher_interpreter"])

        basic_candidate_valid? &&
          File.realpath(@candidate) == @installation_identity.fetch("realpath")
      rescue JSON::ParserError, KeyError, SystemCallError
        false
      end

      private

      def basic_candidate_valid?
        File.file?(@candidate) && !File.symlink?(@candidate) &&
          File.executable?(@candidate) &&
          Digest::SHA256.file(@candidate).hexdigest == @expected_digest
      end

      def verified_receipt
        receipt_path = @installation_identity.fetch("receipt_path")
        raise KeyError unless regular_file?(receipt_path)
        raise KeyError unless
          Digest::SHA256.file(receipt_path).hexdigest ==
            @installation_identity.fetch("receipt_sha256")

        JSON.parse(File.binread(receipt_path))
      end

      def verified_manifest(receipt)
        record = receipt.fetch("tree_manifest")
        path = record.fetch("path")
        raise KeyError unless regular_file?(path)
        raise KeyError unless Digest::SHA256.file(path).hexdigest == record.fetch("sha256")

        JSON.parse(File.binread(path))
      end

      def current_tree(root)
        entries = []
        directories = 0
        total_bytes = 0
        tree_paths(root).each do |path|
          relative = Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
          raise KeyError if Pathname.new(relative).each_filename.count > MAX_TREE_DEPTH

          stat = File.lstat(path)
          record = { "path" => relative, "mode" => stat.mode & 0o7777 }
          if stat.file?
            total_bytes += stat.size
            record.merge!(
              "type" => "file",
              "size" => stat.size,
              "sha256" => Digest::SHA256.file(path).hexdigest
            )
          elsif stat.directory?
            directories += 1
            record["type"] = "directory"
          elsif stat.symlink?
            resolved = File.realpath(path)
            raise KeyError unless resolved.start_with?("#{root}/")

            record.merge!(
              "type" => "symlink",
              "target" => File.readlink(path),
              "resolved_path" =>
                Pathname.new(resolved).relative_path_from(Pathname.new(root)).to_s
            )
          else
            raise KeyError
          end
          entries << record
        end
        {
          "schema" => "hive-live-agent-installed-tree",
          "schema_version" => 1,
          "install_root" => root,
          "entry_count" => entries.length,
          "directory_count" => directories,
          "total_file_bytes" => total_bytes,
          "entries" => entries
        }
      end

      def tree_paths(root)
        paths = []
        queue = Dir.children(root).sort.map { |name| File.join(root, name) }
        until queue.empty?
          path = queue.shift
          paths << path
          raise KeyError if paths.length > MAX_TREE_ENTRIES

          stat = File.lstat(path)
          if stat.directory? && !stat.symlink?
            queue.concat(Dir.children(path).sort.map { |name| File.join(path, name) })
          end
        end
        paths.sort
      end

      def read_only_tree?(root, manifest)
        root_mode = File.lstat(root).mode & 0o7777
        (root_mode & 0o222).zero? &&
          manifest.fetch("entries").all? do |entry|
            entry["type"] == "symlink" || (entry.fetch("mode") & 0o222).zero?
          end
      end

      def interpreter_valid?(record)
        realpath = File.realpath(record.fetch("configured_path"))
        return false unless realpath == record.fetch("realpath")
        return false unless Digest::SHA256.file(realpath).hexdigest == record.fetch("sha256")

        version, status = interpreter_version(realpath)
        status.success? && version == record.fetch("version")
      end

      def launcher_interpreter_valid?(record)
        !record || interpreter_valid?(record)
      end

      def interpreter_version(realpath)
        stdout, stderr, status = Open3.capture3(
          {}, realpath, "--version", unsetenv_others: true
        )
        output = stdout.empty? ? stderr : stdout
        [
          output.byteslice(0, VERSION_LIMIT).to_s.scrub.lines.first.to_s.strip,
          status
        ]
      end

      def regular_file?(path)
        stat = File.lstat(path)
        stat.file? && !stat.symlink?
      rescue SystemCallError
        false
      end
    end
  end
end
