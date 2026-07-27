require "digest"
require "fileutils"
require "hive/atomic_file"

module Hive
  # SHA-256 snapshot/diff helper for orchestrator-owned files.
  #
  # Multiple stages (4-execute, 6-review's runner / triage / ci-fix) all
  # need the same primitive: snapshot a small set of files before
  # spawning a sub-agent, snapshot again after, and surface the names
  # that differ so a tampering attempt lands a structured error marker
  # (ADR-013 / ADR-019 / ADR-021).
  #
  # The fix-agent gets task-folder context but writes only to the worktree
  # itself. Plans, pointers, markers, and durable identity state therefore
  # share this single protected-file source of truth.
  module ProtectedFiles
    class RestoreError < StandardError; end

    # Files the orchestrator owns; sub-spawns must not modify them.
    ORCHESTRATOR_OWNED = %w[
      plan.md worktree.yml handoff.yml task.md task-journal.jsonl task-projection.json
    ].freeze

    module_function

    # Snapshot SHA-256 of every name in `names` resolved against `root`.
    # Missing files are recorded as `nil` so a deletion is detected as
    # a difference (otherwise a missing file would compare equal to a
    # missing file across the snapshot pair).
    def snapshot(root, names = ORCHESTRATOR_OWNED)
      names.each_with_object({}) do |name, h|
        h[name] = fingerprint(File.join(root, name))
      end
    end

    # Snapshot a small labeled set of absolute controller paths. Managed
    # worktree agents can legitimately mutate refs and indexes through Git,
    # but the .git pointer and repository configuration remain controller
    # trust anchors and must not change across the spawn.
    def snapshot_paths(paths)
      paths.to_h { |label, path| [ label, fingerprint(path) ] }
    end

    # Structured no-follow identities used by the Artifact Firewall. The
    # legacy #snapshot shape remains content-digest compatible, while this
    # richer observation also detects mode and file-type substitutions.
    def observe_paths(paths)
      paths.to_h { |label, path| [ label, identity(path) ] }
    end

    # Capture the bytes needed to restore controller-owned files immediately
    # after a spawn. The capture stays in controller memory; an agent never
    # receives a path it can rewrite and establish as a new trusted baseline.
    def capture(root, names = ORCHESTRATOR_OWNED)
      names.to_h do |name|
        validate_relative_name!(name)
        [ name, capture_path(File.join(root, name)) ]
      end
    end

    def capture_paths(paths)
      paths.to_h { |label, path| [ label, capture_path(path) ] }
    end

    # Restore only names that the integrity diff proved changed. Missing files
    # are removed, while regular files are atomically replaced with their
    # original bytes and mode. Unexpected directories fail closed rather than
    # recursively deleting agent-controlled data.
    def restore(root, captured, names)
      Array(names).each do |name|
        validate_relative_name!(name)
        restore_path(File.join(root, name), captured.fetch(name))
      end
      verify_restored!(root, captured, names)
      true
    end

    def restore_paths(paths, captured, labels)
      Array(labels).each do |label|
        restore_path(paths.fetch(label), captured.fetch(label))
      end
      mismatches = Array(labels).reject do |label|
        restored_entry?(paths.fetch(label), captured.fetch(label))
      end
      raise RestoreError, "protected paths could not be restored: #{mismatches.join(', ')}" unless mismatches.empty?

      true
    end

    def restore_safely(root, captured, names)
      [ restore(root, captured, names), nil ]
    rescue StandardError => e
      [ false, "#{e.class}: #{e.message}" ]
    end

    def restore_paths_safely(paths, captured, labels)
      [ restore_paths(paths, captured, labels), nil ]
    rescue StandardError => e
      [ false, "#{e.class}: #{e.message}" ]
    end

    # Names that differ between two snapshots produced by #snapshot.
    def diff(before, after)
      before.keys.reject { |k| before[k] == after[k] }
    end

    def fingerprint(path)
      stat = File.lstat(path)
      if stat.file?
        content = File.open(path, File::RDONLY | File::NOFOLLOW, &:read)
        ::Digest::SHA256.hexdigest(content)
      else
        # File type is part of the integrity snapshot. A symlink to a file
        # with identical contents must still count as tampering.
        "#{stat.ftype}:#{stat.symlink? ? File.readlink(path) : stat.mode}"
      end
    rescue Errno::ENOENT
      nil
    end
    private_class_method :fingerprint

    def capture_path(path)
      stat = File.lstat(path)
      unless stat.file?
        return {
          kind: :unrestorable,
          fingerprint: fingerprint(path),
          identity: identity(path)
        }
      end

      File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
        opened_stat = file.stat
        unless opened_stat.file?
          return {
            kind: :unrestorable,
            fingerprint: "#{opened_stat.ftype}:#{opened_stat.mode}",
            identity: {
              kind: opened_stat.ftype.to_sym,
              mode: opened_stat.mode & 0o777
            }.freeze
          }
        end

        content = file.read
        digest = ::Digest::SHA256.hexdigest(content)
        {
          kind: :file,
          content: content,
          mode: opened_stat.mode & 0o777,
          fingerprint: digest,
          identity: {
            kind: :file,
            sha256: digest,
            mode: opened_stat.mode & 0o777
          }.freeze
        }
      end
    rescue Errno::ENOENT
      { kind: :missing, fingerprint: nil, identity: { kind: :missing }.freeze }
    end
    private_class_method :capture_path

    def restore_path(path, entry)
      if File.directory?(path) && !File.symlink?(path)
        raise RestoreError, "refusing to replace protected path directory: #{path}"
      end

      case entry.fetch(:kind)
      when :missing
        FileUtils.rm_f(path)
      when :file
        Hive::AtomicFile.write(
          path, entry.fetch(:content), mode: entry.fetch(:mode)
        )
        File.chmod(entry.fetch(:mode), path)
      when :unrestorable
        raise RestoreError, "protected non-file path cannot be reconstructed safely: #{path}"
      else
        raise RestoreError, "unknown protected capture type for #{path}"
      end
    end
    private_class_method :restore_path

    def verify_restored!(root, captured, names)
      mismatches = Array(names).reject do |name|
        restored_entry?(File.join(root, name), captured.fetch(name))
      end
      raise RestoreError, "protected files could not be restored: #{mismatches.join(', ')}" unless mismatches.empty?
    end
    private_class_method :verify_restored!

    def identity(path)
      stat = File.lstat(path)
      case stat.ftype
      when "file"
        File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
          opened_stat = file.stat
          if opened_stat.file?
            {
              kind: :file,
              sha256: ::Digest::SHA256.hexdigest(file.read),
              mode: opened_stat.mode & 0o777
            }.freeze
          else
            {
              kind: opened_stat.ftype.to_sym,
              mode: opened_stat.mode & 0o777
            }.freeze
          end
        end
      when "link"
        { kind: :symlink, target: File.readlink(path) }.freeze
      when "directory"
        { kind: :directory, mode: stat.mode & 0o777 }.freeze
      else
        { kind: stat.ftype.to_sym, mode: stat.mode & 0o777 }.freeze
      end
    rescue Errno::ENOENT
      { kind: :missing }.freeze
    rescue SystemCallError, IOError => e
      { kind: :unreadable, error_class: e.class.name }.freeze
    end
    private_class_method :identity

    def restored_entry?(path, entry)
      expected_identity = entry[:identity]
      if expected_identity
        identity(path) == expected_identity
      else
        fingerprint(path) == entry.fetch(:fingerprint)
      end
    end
    private_class_method :restored_entry?

    def validate_relative_name!(name)
      value = name.to_s
      expanded = File.expand_path(value, "/")
      unless !value.empty? && !value.start_with?("/") && expanded.start_with?("/") &&
             !value.split(File::SEPARATOR).include?("..")
        raise ArgumentError, "protected filename must stay relative: #{name.inspect}"
      end
    end
    private_class_method :validate_relative_name!
  end
end
