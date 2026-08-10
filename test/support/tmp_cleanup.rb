require "fileutils"
require "tmpdir"

module HiveTestTmpCleanup
  DEFAULT_MIN_AGE_SECONDS = 24 * 60 * 60

  # These are test-only names created by test/test_helper.rb or by the few
  # tests that need a source tree to outlive the statement that creates it.
  # Keep this narrower than `hive-*`: production code also uses Dir.tmpdir.
  TMP_BASE_SOURCE = /(?:
    hive-test[a-z0-9_-]* |
    hive-global[a-z0-9_-]* |
    hive-web-(?:bad|nested|no-gemfile|src) |
    hive-noapp |
    hive-pairing-command
  )(?<date>\d{8})-(?<pid>\d+)-[a-z0-9]+/x.source.freeze
  TMP_RELATED_SUFFIX_SOURCE = /(?:-worktrees|\.origin\.git|\.patrol-[0-9a-f]+\.lock)/.source.freeze
  TMP_BASE_PATTERN = /\A#{TMP_BASE_SOURCE}\z/x.freeze
  TMP_ENTRY_PATTERN = /\A#{TMP_BASE_SOURCE}(?:#{TMP_RELATED_SUFFIX_SOURCE})?\z/x.freeze
  LEGACY_WORKTREE_PATTERN = /\Ahive-test[a-z0-9_-]*\d{8}-(?<pid>\d+)-[a-z0-9]+\.worktrees\z/.freeze

  SweepResult = Data.define(:removed, :skipped_live, :skipped_recent, :skipped_unowned, :failed)

  class UnsafePath < StandardError; end
  class CleanupError < StandardError; end

  module_function

  def remove!(path, root: Dir.tmpdir, pattern: TMP_ENTRY_PATTERN)
    target = File.expand_path(path)
    root = File.expand_path(root)
    basename = File.basename(target)

    unless File.dirname(target) == root && pattern.match?(basename)
      raise UnsafePath, "refusing to remove non-test tmp path: #{target}"
    end

    return false unless File.exist?(target) || File.symlink?(target)

    stat = File.lstat(target)
    unless stat.uid == Process.uid
      raise UnsafePath, "refusing to remove test tmp path owned by uid #{stat.uid}: #{target}"
    end

    # remove_entry_secure repairs directory permissions while walking a sticky
    # world-writable tmpdir. Ruby falls back to plain removal for a private
    # TMPDIR (and for the legacy ~/Dev root), so make owned directories writable
    # there first. Plain rm_rf silently leaves the 0555/0444 trees produced by
    # managed-package tests.
    parent_stat = File.stat(root)
    if stat.directory? && !parent_stat.world_writable?
      FileUtils.chmod_R(0o700, target, force: true)
    end
    FileUtils.rm_rf(target, secure: true)
    if File.exist?(target) || File.symlink?(target)
      raise CleanupError, "test tmp path still exists after removal: #{target}"
    end

    true
  end

  def remove_all!(paths)
    failures = Array(paths).compact.reverse_each.filter_map do |path|
      remove_with_related!(path)
      nil
    rescue StandardError => e
      "#{path}: #{e.class}: #{e.message}"
    end
    return if failures.empty?

    raise CleanupError, "failed to remove tracked test tmp paths:\n#{failures.join("\n")}"
  end

  def remove_with_related!(path, root: Dir.tmpdir)
    target = File.expand_path(path)
    root = File.expand_path(root)
    basename = File.basename(target)
    unless File.dirname(target) == root && TMP_BASE_PATTERN.match?(basename)
      raise UnsafePath, "refusing to remove related paths for non-test tmp path: #{target}"
    end

    related = if Dir.exist?(root)
      Dir.children(root).filter_map do |entry|
        suffix = entry.delete_prefix(basename)
        next if suffix == entry || !/\A#{TMP_RELATED_SUFFIX_SOURCE}\z/.match?(suffix)

        File.join(root, entry)
      end
    else
      []
    end

    failures = (related + [ target ]).filter_map do |entry|
      remove!(entry, root: root)
      nil
    rescue StandardError => e
      "#{entry}: #{e.class}: #{e.message}"
    end
    return if failures.empty?

    raise CleanupError, "failed to remove test tmp path family:\n#{failures.join("\n")}"
  end

  def sweep(tmp_root: Dir.tmpdir, legacy_root: File.expand_path("~/Dev"),
            min_age_seconds: DEFAULT_MIN_AGE_SECONDS, now: Time.now,
            process_alive: method(:process_alive?))
    min_age_seconds = Integer(min_age_seconds)
    raise ArgumentError, "min_age_seconds must be non-negative" if min_age_seconds.negative?

    candidates = candidates_under(tmp_root, TMP_ENTRY_PATTERN)
    if legacy_root && Dir.exist?(legacy_root)
      candidates.concat(candidates_under(legacy_root, LEGACY_WORKTREE_PATTERN))
    end

    removed = []
    skipped_live = []
    skipped_recent = []
    skipped_unowned = []
    failed = []

    candidates.uniq.each do |candidate|
      path = candidate.fetch(:path)
      stat = File.lstat(path)
      if stat.uid != Process.uid
        skipped_unowned << path
      elsif process_alive.call(candidate.fetch(:pid))
        skipped_live << path
      elsif stat.mtime > now - min_age_seconds
        skipped_recent << path
      else
        remove!(path, root: candidate.fetch(:root), pattern: candidate.fetch(:pattern))
        removed << path
      end
    rescue Errno::ENOENT
      # A concurrently finishing test removed its own directory.
      next
    rescue StandardError => e
      failed << { path: path, error: "#{e.class}: #{e.message}" }
    end

    SweepResult.new(
      removed: removed.freeze,
      skipped_live: skipped_live.freeze,
      skipped_recent: skipped_recent.freeze,
      skipped_unowned: skipped_unowned.freeze,
      failed: failed.freeze
    )
  end

  def process_alive?(pid)
    Process.kill(0, Integer(pid))
    true
  rescue ArgumentError, TypeError, Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  def candidates_under(root, pattern)
    root = File.expand_path(root)
    return [] unless Dir.exist?(root)

    Dir.children(root).filter_map do |basename|
      match = pattern.match(basename)
      next unless match

      {
        path: File.join(root, basename),
        root: root,
        pattern: pattern,
        pid: Integer(match[:pid])
      }
    end
  end
  private_class_method :candidates_under
end
