require "digest"
require "fileutils"
require "json"
require "pathname"
require "time"
require "hive/agent_git_gate"
require "hive/atomic_file"
require "hive/artifacts/project_command_sandbox"

module Hive
  module Artifacts
    # Recoverable bridge for evidence attempts produced by an older Hive
    # runtime which bound Rails' runtime directories directly into the source
    # worktree. New attempts use ProjectCommandSandbox's private overlay and
    # cannot create this residue. A task already stopped by the old runtime,
    # however, would otherwise remain dirty forever and every automatic retry
    # would fail before the evidence producer could start.
    #
    # This is deliberately narrower than `git clean`: it runs only for the
    # exact artifact identity failure, accepts only untracked regular files in
    # the runtime directories the sandbox now overlays, and renames them into
    # a task-owned quarantine with a digest journal. Tracked/staged edits,
    # symlinks, special files, other paths, and large payloads all fail closed.
    class RuntimeResidueRecovery
      MAX_FILE_BYTES = 64 * 1024 * 1024
      MAX_TOTAL_BYTES = 128 * 1024 * 1024
      MARKER_REASON = "outcome_evidence_invalid"
      MARKER_DIAGNOSTIC = "implementation worktree must be clean"
      Result = Data.define(:status, :receipt_path, :paths)

      class RecoveryError < Hive::Error; end

      def recover(task:, marker:, intended_stage:)
        return Result.new(status: :not_applicable, receipt_path: nil, paths: []) unless
          applicable?(marker, intended_stage)

        worktree = File.realpath(task.worktree_path.to_s)
        marker_id = marker.attrs.fetch("marker_id").to_s
        raise RecoveryError, "artifact runtime residue marker identity is missing" if marker_id.empty?

        quarantine = File.join(
          task.folder, "outcome-evidence", "runtime-residue-quarantine", marker_id
        )
        receipt_path = File.join(quarantine, "receipt.json")
        status = git_status(worktree)
        if status.empty?
          completed = complete_existing_receipt(receipt_path, worktree:, quarantine:)
          return completed if completed

          return Result.new(status: :clean, receipt_path: nil, paths: [])
        end

        paths = untracked_runtime_paths(status)
        receipt = load_or_prepare_receipt(
          receipt_path:, quarantine:, worktree:, marker_id:, paths:
        )
        move_entries!(receipt, worktree:, quarantine:)
        receipt = receipt.merge(
          "status" => "quarantined", "completed_at" => Time.now.utc.iso8601(6)
        )
        Hive::AtomicFile.write(receipt_path, JSON.pretty_generate(receipt) + "\n", mode: 0o600)
        prune_empty_runtime_parents(worktree, paths)

        remaining = git_status(worktree)
        unless remaining.empty?
          raise RecoveryError,
                "artifact runtime residue quarantine left the implementation worktree dirty"
        end

        Result.new(status: :quarantined, receipt_path: receipt_path, paths: paths.freeze)
      rescue SystemCallError, JSON::ParserError,
             Hive::AgentGitGate::Error => e
        raise RecoveryError, "artifact runtime residue recovery failed: #{e.message}"
      end

      private

      def applicable?(marker, intended_stage)
        intended_stage.to_s == "7-artifacts" && # coding-scoped: coding artifact evidence recovery
          marker.name.to_s == "error" &&
          marker.attrs["reason"].to_s == MARKER_REASON &&
          marker.attrs["diagnostic"].to_s == MARKER_DIAGNOSTIC
      end

      def git_status(worktree)
        result = Hive::AgentGitGate.read(
          worktree, :status, max_stdout_bytes: 4 * 1024 * 1024
        )
        unless result.success?
          diagnostic = result.stderr.to_s.strip
          diagnostic = "bounded output exceeded" if result.overflow
          raise RecoveryError, "artifact runtime residue Git status failed: #{diagnostic}"
        end

        result.stdout.to_s.b.split("\0", -1).reject(&:empty?)
      end

      def untracked_runtime_paths(entries)
        paths = entries.map do |entry|
          unless entry.start_with?("?? ")
            raise RecoveryError,
                  "artifact runtime residue includes tracked or staged worktree changes"
          end

          path = entry.byteslice(3..).to_s.force_encoding(Encoding::UTF_8)
          unless path.valid_encoding?
            raise RecoveryError, "artifact runtime residue path is not valid UTF-8"
          end
          validate_path!(path)
        end
        paths.uniq.sort
      end

      def validate_path!(path)
        pathname = Pathname.new(path)
        clean = pathname.cleanpath.to_s
        parts = pathname.each_filename.to_a
        allowed = Hive::Artifacts::ProjectCommandSandbox::WRITABLE_SOURCE_DIRS
        unless !path.empty? && path.bytesize <= 4096 && !pathname.absolute? &&
               clean == path && parts.length >= 2 && allowed.include?(parts.first)
          raise RecoveryError,
                "artifact runtime residue includes a path outside managed runtime directories"
        end

        path
      end

      def load_or_prepare_receipt(receipt_path:, quarantine:, worktree:, marker_id:, paths:)
        if File.exist?(receipt_path)
          receipt = JSON.parse(File.binread(receipt_path))
          unless receipt["schema"] == "hive-artifact-runtime-residue" &&
                 receipt["schema_version"] == 1 && receipt["marker_id"] == marker_id &&
                 receipt["worktree"] == worktree &&
                 (paths - Array(receipt["paths"])).empty?
            raise RecoveryError, "artifact runtime residue quarantine receipt conflicts"
          end
          return receipt
        end

        FileUtils.mkdir_p(quarantine, mode: 0o700)
        entries = paths.map { |path| entry_receipt(worktree, path) }
        total = entries.sum { |entry| entry.fetch("size") }
        if total > MAX_TOTAL_BYTES
          raise RecoveryError, "artifact runtime residue exceeds the quarantine byte limit"
        end

        receipt = {
          "schema" => "hive-artifact-runtime-residue",
          "schema_version" => 1,
          "status" => "prepared",
          "marker_id" => marker_id,
          "worktree" => worktree,
          "paths" => paths,
          "entries" => entries,
          "prepared_at" => Time.now.utc.iso8601(6)
        }
        Hive::AtomicFile.write(receipt_path, JSON.pretty_generate(receipt) + "\n", mode: 0o600)
        receipt
      end

      def complete_existing_receipt(receipt_path, worktree:, quarantine:)
        return nil unless File.file?(receipt_path) && !File.symlink?(receipt_path)

        receipt = JSON.parse(File.binread(receipt_path))
        return nil unless receipt["schema"] == "hive-artifact-runtime-residue" &&
                          receipt["schema_version"] == 1 &&
                          receipt["worktree"] == worktree

        move_entries!(receipt, worktree:, quarantine:)
        receipt = receipt.merge(
          "status" => "quarantined", "completed_at" => Time.now.utc.iso8601(6)
        )
        Hive::AtomicFile.write(receipt_path, JSON.pretty_generate(receipt) + "\n", mode: 0o600)
        Result.new(
          status: :quarantined, receipt_path: receipt_path,
          paths: receipt.fetch("paths").freeze
        )
      end

      def entry_receipt(worktree, path)
        source = contained_path(worktree, path)
        stat = File.lstat(source)
        unless stat.file? && !stat.symlink?
          raise RecoveryError, "artifact runtime residue includes a non-regular file"
        end
        if stat.size > MAX_FILE_BYTES
          raise RecoveryError, "artifact runtime residue file exceeds the quarantine byte limit"
        end

        {
          "path" => path,
          "size" => stat.size,
          "mode" => stat.mode & 0o7777,
          "sha256" => Digest::SHA256.file(source).hexdigest,
          "device" => stat.dev,
          "inode" => stat.ino
        }
      end

      def move_entries!(receipt, worktree:, quarantine:)
        receipt.fetch("entries").each do |entry|
          path = entry.fetch("path")
          source = contained_path(worktree, path, require_parent: false)
          destination = contained_path(quarantine, path, require_parent: false)
          if File.exist?(destination)
            verify_quarantined_entry!(destination, entry)
            raise RecoveryError, "artifact runtime residue exists in source and quarantine" if
              File.exist?(source) || File.symlink?(source)
            next
          end

          source = contained_path(worktree, path)
          verify_source_entry!(source, entry)
          FileUtils.mkdir_p(File.dirname(destination), mode: 0o700)
          File.rename(source, destination)
          verify_quarantined_entry!(destination, entry)
        end
      end

      def verify_source_entry!(source, entry)
        stat = File.lstat(source)
        unless stat.file? && !stat.symlink? && stat.dev == entry.fetch("device") &&
               stat.ino == entry.fetch("inode") && stat.size == entry.fetch("size") &&
               Digest::SHA256.file(source).hexdigest == entry.fetch("sha256")
          raise RecoveryError, "artifact runtime residue changed after it was journaled"
        end
      end

      def verify_quarantined_entry!(destination, entry)
        stat = File.lstat(destination)
        unless stat.file? && !stat.symlink? && stat.size == entry.fetch("size") &&
               Digest::SHA256.file(destination).hexdigest == entry.fetch("sha256")
          raise RecoveryError, "artifact runtime residue quarantine entry is invalid"
        end
      end

      def contained_path(root, relative, require_parent: true)
        expanded = File.expand_path(relative, root)
        unless expanded.start_with?("#{root}#{File::SEPARATOR}")
          raise RecoveryError, "artifact runtime residue path escapes its root"
        end
        if require_parent
          parent = File.realpath(File.dirname(expanded))
          unless parent == root || parent.start_with?("#{root}#{File::SEPARATOR}")
            raise RecoveryError, "artifact runtime residue parent escapes its root"
          end
        end
        expanded
      end

      def prune_empty_runtime_parents(worktree, paths)
        paths.each do |path|
          runtime_root = File.join(worktree, Pathname.new(path).each_filename.first)
          parent = File.dirname(File.join(worktree, path))
          while parent.start_with?("#{runtime_root}#{File::SEPARATOR}")
            begin
              Dir.rmdir(parent)
              parent = File.dirname(parent)
            rescue Errno::ENOTEMPTY, Errno::ENOENT
              break
            end
          end
        end
      end
    end
  end
end
