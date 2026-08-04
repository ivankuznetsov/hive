# frozen_string_literal: true

require "digest"
require_relative "workflow_creator"

module HiveLiveAgentProof
  class WorkflowCreatorInstallation
    class Error < StandardError; end
    MESSAGE = "workflow-creator installation closure is invalid"
    MAX_FILES = 512
    MAX_NODES = 1_024
    MAX_FILE_BYTES = 268_435_456
    MAX_TOTAL_BYTES = 1_073_741_824
    MAX_PATH_BYTES = 1_024
    CHUNK_BYTES = 65_536
    READ_FLAGS = if defined?(File::NOFOLLOW) && defined?(File::NONBLOCK)
      File::RDONLY | File::NOFOLLOW | File::NONBLOCK
    end

    class << self
      def candidate!(root:, candidate_sha:, manifest:, inventory:, audit_gateway:, executable:,
                     interpreter_or_launcher:, lock:, package:)
        build(
          kind: "candidate", root:, candidate_sha:, manifest:, inventory:, version: nil,
          role_paths: { "audit_gateway" => audit_gateway, "executable" => executable,
                        "interpreter_or_launcher" => interpreter_or_launcher, "lock" => lock, "package" => package }
        )
      end

      def openclaw!(root:, version:, candidate_sha:, manifest:, inventory:, executable:,
                    interpreter_or_launcher:, lock:, package:)
        build(
          kind: "openclaw", root:, candidate_sha:, manifest:, inventory:, version:,
          role_paths: { "executable" => executable, "interpreter_or_launcher" => interpreter_or_launcher,
                        "lock" => lock, "package" => package }
        )
      end
      private

      def build(kind:, root:, candidate_sha:, manifest:, inventory:, version:, role_paths:)
        input = WorkflowCreator::Values.capture(
          "root" => root, "candidate_sha" => candidate_sha, "manifest" => manifest,
          "inventory" => inventory, "version" => version, "role_paths" => role_paths
        ).value
        root_path, admitted_root = admit_root(input.fetch("root"))
        records, directories = scan_root(root_path, admitted_root)
        expected = normalize_inventory(root_path, input.fetch("inventory"))
        raise Error, MESSAGE unless records.map { |record| record.fetch("path") } == expected
        required = required_roles(kind, root_path, input.fetch("role_paths"), records)
        verify_directories!(directories)
        document = manifest_document(kind, input, required, records)
        WorkflowCreator.validate_installation!(
          document:, kind:, manifest: input.fetch("manifest"), candidate_sha: input.fetch("candidate_sha")
        )
      rescue StandardError
        raise Error, MESSAGE, cause: nil
      end

      def admit_root(raw)
        root = File.expand_path(raw)
        stat = File.lstat(root)
        valid = File.realpath(root) == root && safe_directory?(stat)
        raise Error, MESSAGE unless valid && READ_FLAGS
        [ root, identity(stat) ]
      end

      def scan_root(root, admitted_root)
        records = []
        directories = []
        queue = [ [ "", root ] ]
        nodes = 0
        total = 0
        until queue.empty?
          relative, directory = queue.shift
          stat = File.lstat(directory)
          raise Error, MESSAGE unless safe_directory?(stat)
          raise Error, MESSAGE if relative.empty? && identity(stat) != admitted_root
          directories << [ directory, identity(stat) ]
          children = Dir.each_child(directory).take(MAX_NODES + 1).sort
          nodes += children.length
          raise Error, MESSAGE if nodes > MAX_NODES
          children.each do |name|
            path = relative.empty? ? name : File.join(relative, name)
            normalized = normalize_relative(path)
            absolute = File.join(root, normalized)
            child = File.lstat(absolute)
            if child.directory?
              queue << [ normalized, absolute ]
            elsif child.file?
              total += child.size
              raise Error, MESSAGE if total > MAX_TOTAL_BYTES
              records << file_record(absolute, normalized, child)
              raise Error, MESSAGE if records.length > MAX_FILES
            else
              raise Error, MESSAGE
            end
          end
        end
        [ records.sort_by { |record| record.fetch("path") }, directories ]
      end
      def safe_directory?(stat)
        stat.directory? && stat.uid == Process.uid && (stat.mode & 0o022).zero?
      end
      def file_record(path, relative, lstat)
        valid = lstat.file? && lstat.nlink == 1 && lstat.uid == Process.uid
        valid &&= (lstat.mode & 0o022).zero? && lstat.size.between?(0, MAX_FILE_BYTES)
        raise Error, MESSAGE unless valid
        digest = Digest::SHA256.new
        File.open(path, READ_FLAGS) do |file|
          opened = file.stat
          raise Error, MESSAGE unless identity(opened) == identity(lstat)
          while (chunk = file.read(CHUNK_BYTES))
            digest.update(chunk)
          end
          raise Error, MESSAGE unless identity(file.stat) == identity(opened)
        end
        { "path" => relative, "sha256" => digest.hexdigest, "size" => lstat.size }
      end

      def normalize_inventory(root, paths)
        normalized = paths.map { |path| role_relative(root, path) }
        raise Error, MESSAGE unless normalized.length.between?(1, MAX_FILES)
        raise Error, MESSAGE unless normalized.uniq.length == normalized.length
        normalized.sort
      end

      def required_roles(kind, root, role_paths, records)
        by_path = records.to_h { |record| [ record.fetch("path"), record ] }
        roles = WorkflowCreator::Vocabulary.fetch("member_roles").fetch(kind)
        raise Error, MESSAGE unless role_paths.keys == roles
        required = roles.to_h do |role|
          relative = role_relative(root, role_paths.fetch(role))
          [ role, by_path.fetch(relative) ]
        end
        raise Error, MESSAGE unless required.values.uniq.length == roles.length
        required
      end

      def role_relative(root, path)
        if path.start_with?(File::SEPARATOR)
          expanded = File.expand_path(path)
          prefix = "#{root}#{File::SEPARATOR}"
          raise Error, MESSAGE unless expanded == path && expanded.start_with?(prefix)
          normalize_relative(expanded.delete_prefix(prefix))
        else
          normalize_relative(path)
        end
      end

      def normalize_relative(path)
        owned = WorkflowCreator::Values.capture(path).value
        safe = owned.bytesize <= MAX_PATH_BYTES
        safe &&= WorkflowCreator::TextSafety.safe_relative_path?(owned)
        safe &&= File.expand_path(owned, File::SEPARATOR) == File.join(File::SEPARATOR, owned)
        raise Error, MESSAGE unless safe
        owned
      end

      def verify_directories!(directories)
        directories.each do |path, expected|
          raise Error, MESSAGE unless identity(File.lstat(path)) == expected
        end
      end

      def manifest_document(kind, input, required, inventory)
        closure = WorkflowCreator::Values.capture("required_roles" => required, "inventory" => inventory)
        total = inventory.sum { |record| record.fetch("size") }
        raise Error, MESSAGE unless total.between?(1, MAX_TOTAL_BYTES)
        version = kind == "candidate" ? input.fetch("manifest").fetch("hive_version") : input.fetch("version")
        {
          "schema" => WorkflowCreator::Vocabulary.fetch("installed_schema"), "schema_version" => 1,
          "candidate_sha" => input.fetch("candidate_sha"), "kind" => kind, "version" => version,
          "closure_sha256" => Digest::SHA256.hexdigest(closure.canonical_bytes),
          "required_roles" => required, "inventory" => inventory, "total_size" => total,
          "secret_scan" => { "status" => "passed", "scanner" => WorkflowCreator::Vocabulary.fetch("scanner") }
        }
      end

      def identity(stat)
        %i[dev ino uid mode nlink size mtime ctime].map { |field| stat.public_send(field) }
      end
    end
  end
end
