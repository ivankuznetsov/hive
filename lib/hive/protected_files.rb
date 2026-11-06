require "digest"
require "fileutils"
require "json"
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
      plan.md worktree.yml handoff.yml task.md task-journal.jsonl
    ].freeze

    # Controller-owned append-only logs, keyed to the sibling flock their
    # writer holds. The stage controller and daemon observers (session
    # receipts, GitHub PR outcomes, holds) append to the task journal while an
    # agent custody window is open, so custody must not treat a byte change as
    # tampering: the captured bytes must survive unchanged and every appended
    # line must be a complete authoritative journal record. Restoration keeps
    # such records instead of rolling the log back to the pre-spawn bytes.
    APPEND_ONLY_LOGS = { "task-journal.jsonl" => ".task-journal.lock" }.freeze
    APPEND_ONLY_RECORD_SCHEMA = "hive-task-journal-event".freeze

    module_function

    def append_only_log?(path)
      APPEND_ONLY_LOGS.key?(File.basename(path.to_s))
    end

    # True when an append-only log still starts with its captured bytes (and
    # mode) and everything after them is newly appended journal records.
    # Truncation, rewritten lines, partial lines, and non-journal content all
    # return false.
    def appended_only?(path, entry)
      with_append_lock(path) { appended_only_unlocked?(path, entry) }
    end

    # Snapshot SHA-256 of every name in `names` resolved against `root`.
    # Missing files are recorded as `nil` so a deletion is detected as
    # a difference (otherwise a missing file would compare equal to a
    # missing file across the snapshot pair).
    def snapshot(root, names = ORCHESTRATOR_OWNED)
      names.each_with_object({}) do |name, h|
        h[name] = fingerprint(File.join(root, name))
      end
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
      return with_append_lock(path) { capture_path_unlocked(path) } if append_only_log?(path)

      capture_path_unlocked(path)
    end
    private_class_method :capture_path

    def capture_path_unlocked(path)
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
    private_class_method :capture_path_unlocked

    def restore_path(path, entry)
      if File.directory?(path) && !File.symlink?(path)
        raise RestoreError, "refusing to replace protected path directory: #{path}"
      end
      return restore_append_only_path(path, entry) if append_only_log?(path)

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
      return appended_only?(path, entry) if append_only_log?(path)

      expected_identity = entry[:identity]
      if expected_identity
        identity(path) == expected_identity
      else
        fingerprint(path) == entry.fetch(:fingerprint)
      end
    end
    private_class_method :restored_entry?

    # Rebuild an append-only log as its captured bytes plus every complete
    # journal record found in the current file that the capture did not
    # already hold. Runs under the writer's lock so a concurrent controller
    # append can neither land on the replaced inode nor be dropped.
    def restore_append_only_path(path, entry)
      with_append_lock(path) do
        base, base_mode = append_base(entry)
        raise RestoreError, "protected non-file path cannot be reconstructed safely: #{path}" unless base

        current, = read_regular(path)
        appended = current ? appended_lines(current, record_ids(base), strict: false) : []
        if entry.fetch(:kind) == :missing && appended.empty?
          FileUtils.rm_f(path)
        else
          mode = base_mode || 0o644
          Hive::AtomicFile.write(path, base + appended.join, mode: mode)
          File.chmod(mode, path)
        end
      end
    end
    private_class_method :restore_append_only_path

    def appended_only_unlocked?(path, entry)
      base, base_mode = append_base(entry)
      return false unless base

      current, mode = read_regular(path)
      return entry.fetch(:kind) == :missing && !File.exist?(path) && !File.symlink?(path) unless current
      return false if base_mode && mode != base_mode
      return false unless current.start_with?(base)

      !appended_lines(current.byteslice(base.bytesize..), record_ids(base), strict: true).nil?
    end
    private_class_method :appended_only_unlocked?

    def append_base(entry)
      case entry.fetch(:kind)
      when :file then [ entry.fetch(:content).b, entry.fetch(:mode) ]
      when :missing then [ "".b, nil ]
      end
    end
    private_class_method :append_base

    def read_regular(path)
      File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
        stat = file.stat
        stat.file? ? [ file.read.b, stat.mode & 0o777 ] : nil
      end
    rescue SystemCallError, IOError
      nil
    end
    private_class_method :read_regular

    # Strict: every byte of `text` must be complete, previously unseen journal
    # records (returns nil otherwise). Lenient: salvage only such records.
    def appended_lines(text, known_ids, strict:)
      return nil if strict && !text.empty? && !text.end_with?("\n")

      seen = known_ids.dup
      text.each_line.each_with_object([]) do |line, kept|
        id = line.end_with?("\n") ? journal_record_id(line) : nil
        if id.nil? || seen.include?(id)
          return nil if strict

          next
        end
        seen << id
        kept << line
      end
    end
    private_class_method :appended_lines

    def record_ids(text)
      text.each_line.filter_map { |line| journal_record_id(line) }
    end
    private_class_method :record_ids

    def journal_record_id(line)
      record = JSON.parse(line.dup.force_encoding(Encoding::UTF_8))
      return nil unless record.is_a?(Hash) && record["schema"] == APPEND_ONLY_RECORD_SCHEMA

      id = record["event_id"]
      id.is_a?(String) && !id.empty? ? id : nil
    rescue JSON::ParserError, EncodingError
      nil
    end
    private_class_method :journal_record_id

    # The log writer's own flock. If the lock cannot be opened (missing
    # parent, substituted lock path) custody proceeds unlocked and still
    # fails closed on any partial or foreign line.
    def with_append_lock(path)
      lock_path = File.join(File.dirname(path), APPEND_ONLY_LOGS.fetch(File.basename(path)))
      lock = begin
        File.open(lock_path, File::RDWR | File::CREAT | File::NOFOLLOW, 0o644)
      rescue SystemCallError
        nil
      end
      lock&.flock(File::LOCK_EX)
      yield
    ensure
      lock&.close
    end
    private_class_method :with_append_lock

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
