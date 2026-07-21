require "yaml"
require "hive/atomic_file"
require "hive/worktree"

module Hive
  # Controller-owned local handoff state. U4 extends the phase machine; this
  # initial contract deliberately contains no credentials or agent-authored
  # evidence and is safe to persist on hive/state.
  module DraftPrReceipt
    module_function

    FILENAME = "handoff.yml".freeze
    VERSION = 1
    INITIAL_PHASE = "worktree_created".freeze
    REQUIRED_KEYS = %w[
      version phase repository base_branch base_oid task_branch worktree_path
    ].freeze

    def path(task_folder)
      File.join(task_folder, FILENAME)
    end

    def initialize!(task_folder, expected:, worktree_root:)
      receipt_path = path(task_folder)
      if File.exist?(receipt_path) || File.symlink?(receipt_path)
        return read(task_folder, expected: expected, worktree_root: worktree_root)
      end

      data = validate(expected, worktree_root: worktree_root)
      Hive::AtomicFile.write(receipt_path, data.to_yaml, mode: 0o600)
      read(task_folder, expected: data, worktree_root: worktree_root)
    end

    def read(task_folder, expected: nil, worktree_root:)
      receipt_path = path(task_folder)
      stat = File.lstat(receipt_path)
      raise Hive::WorktreeError, "#{FILENAME} must be a regular file, not a symlink" if stat.symlink?
      raise Hive::WorktreeError, "#{FILENAME} must be a regular file" unless stat.file?

      source = File.read(receipt_path)
      duplicates = duplicate_top_level_keys(source)
      unless duplicates.empty?
        raise Hive::WorktreeError, "#{FILENAME} contains duplicate keys: #{duplicates.join(', ')}"
      end
      raw = YAML.safe_load(source, permitted_classes: [], permitted_symbols: [], aliases: false)
      data = validate(raw, worktree_root: worktree_root)
      if expected
        canonical_expected = validate(expected, worktree_root: worktree_root)
        mismatches = REQUIRED_KEYS.reject { |key| data.fetch(key) == canonical_expected.fetch(key) }
        unless mismatches.empty?
          raise Hive::WorktreeError,
                "#{FILENAME} contradicts saved task state for: #{mismatches.join(', ')}"
        end
      end
      data
    rescue Errno::ENOENT
      raise Hive::WorktreeError, "#{FILENAME} is missing"
    rescue Psych::Exception => e
      raise Hive::WorktreeError, "#{FILENAME} is invalid YAML: #{e.message}"
    end

    def validate(raw, worktree_root:)
      raise Hive::WorktreeError, "#{FILENAME} must contain a mapping" unless raw.is_a?(Hash)

      data = raw.transform_keys(&:to_s)
      missing = REQUIRED_KEYS - data.keys
      unknown = data.keys - REQUIRED_KEYS
      raise Hive::WorktreeError, "#{FILENAME} is missing keys: #{missing.join(', ')}" unless missing.empty?
      raise Hive::WorktreeError, "#{FILENAME} contains unknown keys: #{unknown.join(', ')}" unless unknown.empty?
      raise Hive::WorktreeError, "#{FILENAME} version must be #{VERSION}" unless data["version"] == VERSION
      unless data["phase"] == INITIAL_PHASE
        raise Hive::WorktreeError, "#{FILENAME} phase must be #{INITIAL_PHASE.inspect}"
      end

      repository = data["repository"].to_s.strip.downcase
      unless repository.match?(/\Agithub\.com\/[a-z0-9_.-]+\/[a-z0-9_.-]+\z/i)
        raise Hive::WorktreeError, "#{FILENAME} repository must be a canonical github.com/owner/name identity"
      end
      base_branch = Hive::Worktree.validate_branch_name!(data["base_branch"])
      task_branch = Hive::Worktree.validate_branch_name!(data["task_branch"])
      base_oid = data["base_oid"].to_s.downcase
      unless base_oid.match?(/\A[0-9a-f]{40,64}\z/)
        raise Hive::WorktreeError, "#{FILENAME} base_oid is invalid"
      end
      worktree_path = Hive::Worktree.validate_pointer_path(data["worktree_path"], worktree_root)

      {
        "version" => VERSION,
        "phase" => INITIAL_PHASE,
        "repository" => repository,
        "base_branch" => base_branch,
        "base_oid" => base_oid,
        "task_branch" => task_branch,
        "worktree_path" => worktree_path
      }
    end

    def duplicate_top_level_keys(source)
      keys = source.lines.filter_map do |line|
        match = line.match(/\A([A-Za-z_][A-Za-z0-9_]*):(?:\s|$)/)
        match && match[1]
      end
      keys.tally.select { |_key, count| count > 1 }.keys.sort
    end
    private_class_method :duplicate_top_level_keys
  end
end
