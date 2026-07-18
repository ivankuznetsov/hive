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
        path = File.join(root, name)
        h[name] = File.exist?(path) ? ::Digest::SHA256.hexdigest(File.read(path)) : nil
      end
    end

    # Names that differ between two snapshots produced by #snapshot.
    def diff(before, after)
      before.keys.reject { |k| before[k] == after[k] }
    end
  end
end
