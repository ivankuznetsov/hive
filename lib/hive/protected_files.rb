require "digest"

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
    # Files the orchestrator owns; sub-spawns must not modify them.
    ORCHESTRATOR_OWNED = %w[
      plan.md worktree.yml task.md task-journal.jsonl task-projection.json
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
  end
end
