require "securerandom"
require "time"
require "uri"
require "yaml"
require "hive/atomic_file"
require "hive/worktree"

module Hive
  # Strict, controller-owned state for the worktree -> draft-PR handoff.
  # Only identities and mutation receipts live here; agent prose, command
  # output, credentials, and error payloads are deliberately excluded.
  module DraftPrReceipt
    module_function

    FILENAME = "handoff.yml".freeze
    VERSION = 1
    MAX_BYTES = 64 * 1024
    INITIAL_PHASE = "worktree_created".freeze
    PHASES = %w[
      worktree_created
      agent_validated
      push_intent
      branch_pushed
      pr_create_intent
      pr_observed
      terminal
    ].freeze
    BASE_KEYS = %w[
      version phase repository base_branch base_oid task_branch worktree_path
    ].freeze
    OPTIONAL_KEYS = %w[
      head_oid report_sha256 scan_sha256
      push_intent_id push_attempted_at observed_remote_oid pushed_at
      pr_create_intent_id pr_create_attempted_at
      pr_number pr_url pr_state observed_at
      terminal_outcome terminal_at error_reason
    ].freeze
    ALL_KEYS = (BASE_KEYS + OPTIONAL_KEYS).freeze
    REQUIRED_BY_PHASE = {
      "worktree_created" => BASE_KEYS,
      "agent_validated" => BASE_KEYS + %w[head_oid report_sha256],
      "push_intent" => BASE_KEYS + %w[head_oid report_sha256 scan_sha256 push_intent_id],
      "branch_pushed" => BASE_KEYS + %w[
        head_oid report_sha256 scan_sha256 push_intent_id push_attempted_at
        observed_remote_oid pushed_at
      ],
      "pr_create_intent" => BASE_KEYS + %w[
        head_oid report_sha256 scan_sha256 push_intent_id push_attempted_at
        observed_remote_oid pushed_at pr_create_intent_id
      ],
      "pr_observed" => BASE_KEYS + %w[
        head_oid report_sha256 scan_sha256 push_intent_id push_attempted_at
        observed_remote_oid pushed_at pr_create_intent_id
        pr_number pr_url pr_state observed_at
      ],
      "terminal" => BASE_KEYS + %w[head_oid report_sha256 terminal_outcome terminal_at]
    }.freeze
    ALLOWED_BY_PHASE = {
      "worktree_created" => BASE_KEYS,
      "agent_validated" => BASE_KEYS + %w[head_oid report_sha256 scan_sha256],
      "push_intent" => BASE_KEYS + %w[
        head_oid report_sha256 scan_sha256 push_intent_id push_attempted_at
      ],
      "branch_pushed" => BASE_KEYS + %w[
        head_oid report_sha256 scan_sha256 push_intent_id push_attempted_at
        observed_remote_oid pushed_at
      ],
      "pr_create_intent" => BASE_KEYS + %w[
        head_oid report_sha256 scan_sha256 push_intent_id push_attempted_at
        observed_remote_oid pushed_at pr_create_intent_id pr_create_attempted_at
      ],
      "pr_observed" => ALL_KEYS - %w[terminal_outcome terminal_at error_reason],
      "terminal" => ALL_KEYS
    }.freeze
    ALLOWED_TRANSITIONS = {
      "worktree_created" => %w[agent_validated terminal],
      "agent_validated" => %w[push_intent terminal],
      "push_intent" => %w[branch_pushed terminal],
      "branch_pushed" => %w[pr_create_intent terminal],
      "pr_create_intent" => %w[pr_observed terminal],
      "pr_observed" => %w[terminal],
      "terminal" => []
    }.freeze
    TERMINAL_OUTCOMES = %w[pr-opened no-fix blocked].freeze
    ERROR_REASONS = %w[
      agent_blocked draft_pr_handoff_failed draft_pr_quarantined
      draft_pr_identity_blocked
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
      source = File.open(receipt_path, File::RDONLY | File::NOFOLLOW) do |file|
        raise Hive::WorktreeError, "#{FILENAME} must be a regular file" unless file.stat.file?

        value = file.read(MAX_BYTES + 1)
        raise Hive::WorktreeError, "#{FILENAME} exceeds #{MAX_BYTES} bytes" if value.bytesize > MAX_BYTES

        value
      end
      duplicates = duplicate_top_level_keys(source)
      unless duplicates.empty?
        raise Hive::WorktreeError, "#{FILENAME} contains duplicate keys: #{duplicates.join(', ')}"
      end
      raw = YAML.safe_load(source, permitted_classes: [], permitted_symbols: [], aliases: false)
      data = validate(raw, worktree_root: worktree_root)
      if expected
        canonical_expected = validate(expected, worktree_root: worktree_root)
        mismatches = BASE_KEYS.reject { |key| data.fetch(key) == canonical_expected.fetch(key) }
        unless mismatches.empty?
          raise Hive::WorktreeError,
                "#{FILENAME} contradicts saved task state for: #{mismatches.join(', ')}"
        end
      end
      data
    rescue Errno::ENOENT
      raise Hive::WorktreeError, "#{FILENAME} is missing"
    rescue Errno::ELOOP
      raise Hive::WorktreeError, "#{FILENAME} must be a regular file, not a symlink"
    rescue Psych::Exception => e
      raise Hive::WorktreeError, "#{FILENAME} is invalid YAML: #{e.message}"
    end

    def advance!(task_folder, from:, to:, attributes: {}, worktree_root:)
      current = read(task_folder, worktree_root: worktree_root)
      unless current.fetch("phase") == from.to_s
        raise Hive::WorktreeError,
              "#{FILENAME} phase is #{current.fetch('phase').inspect}; expected #{from.to_s.inspect}"
      end
      unless ALLOWED_TRANSITIONS.fetch(from.to_s, []).include?(to.to_s)
        raise Hive::WorktreeError,
              "#{FILENAME} cannot advance from #{from.to_s.inspect} to #{to.to_s.inspect}"
      end

      write!(task_folder, current.merge(stringify(attributes)).merge("phase" => to.to_s), worktree_root: worktree_root)
    end

    # Persist mutation-start evidence without inventing another externally
    # visible phase. Existing non-nil receipt values are immutable.
    def update!(task_folder, phase:, attributes:, worktree_root:)
      current = read(task_folder, worktree_root: worktree_root)
      unless current.fetch("phase") == phase.to_s
        raise Hive::WorktreeError,
              "#{FILENAME} phase is #{current.fetch('phase').inspect}; expected #{phase.to_s.inspect}"
      end
      additions = stringify(attributes)
      contradictions = additions.filter_map do |key, value|
        next unless current.key?(key) && !current[key].nil? && current[key] != value

        key
      end
      unless contradictions.empty?
        raise Hive::WorktreeError,
              "#{FILENAME} immutable fields changed: #{contradictions.join(', ')}"
      end

      write!(task_folder, current.merge(additions), worktree_root: worktree_root)
    end

    def mutation_id
      SecureRandom.hex(16)
    end

    def timestamp
      Time.now.utc.iso8601(6)
    end

    def validate(raw, worktree_root:)
      raise Hive::WorktreeError, "#{FILENAME} must contain a mapping" unless raw.is_a?(Hash)

      data = stringify(raw)
      unknown = data.keys - ALL_KEYS
      raise Hive::WorktreeError, "#{FILENAME} contains unknown keys: #{unknown.join(', ')}" unless unknown.empty?
      raise Hive::WorktreeError, "#{FILENAME} version must be #{VERSION}" unless data["version"] == VERSION

      phase = data["phase"].to_s
      raise Hive::WorktreeError, "#{FILENAME} phase is invalid" unless PHASES.include?(phase)
      premature = data.keys - ALLOWED_BY_PHASE.fetch(phase)
      unless premature.empty?
        raise Hive::WorktreeError,
              "#{FILENAME} phase #{phase.inspect} contains premature keys: #{premature.join(', ')}"
      end
      missing = REQUIRED_BY_PHASE.fetch(phase).reject { |key| data.key?(key) && !data[key].nil? }
      raise Hive::WorktreeError, "#{FILENAME} is missing keys: #{missing.join(', ')}" unless missing.empty?

      repository = data["repository"].to_s.strip.downcase
      unless repository.match?(/\Agithub\.com\/[a-z0-9_.-]+\/[a-z0-9_.-]+\z/i)
        raise Hive::WorktreeError, "#{FILENAME} repository must be a canonical github.com/owner/name identity"
      end
      data["repository"] = repository
      data["base_branch"] = Hive::Worktree.validate_branch_name!(data["base_branch"])
      data["task_branch"] = Hive::Worktree.validate_branch_name!(data["task_branch"])
      data["base_oid"] = validate_oid!(data["base_oid"], "base_oid")
      data["worktree_path"] = Hive::Worktree.validate_pointer_path(data["worktree_path"], worktree_root)

      %w[head_oid observed_remote_oid].each do |key|
        data[key] = validate_oid!(data[key], key) if data[key]
      end
      %w[report_sha256 scan_sha256].each do |key|
        next unless data[key]
        unless data[key].to_s.match?(/\A[0-9a-f]{64}\z/i)
          raise Hive::WorktreeError, "#{FILENAME} #{key} is invalid"
        end
        data[key] = data[key].downcase
      end
      %w[push_intent_id pr_create_intent_id].each do |key|
        next unless data[key]
        unless data[key].to_s.match?(/\A[0-9a-f]{32}\z/)
          raise Hive::WorktreeError, "#{FILENAME} #{key} is invalid"
        end
      end
      %w[push_attempted_at pushed_at pr_create_attempted_at observed_at terminal_at].each do |key|
        data[key] = validate_time!(data[key], key) if data[key]
      end
      if data["observed_remote_oid"] && data["head_oid"] && data["observed_remote_oid"] != data["head_oid"]
        raise Hive::WorktreeError, "#{FILENAME} observed_remote_oid must equal head_oid"
      end
      if data["pr_number"]
        number = Integer(data["pr_number"].to_s, 10)
        raise Hive::WorktreeError, "#{FILENAME} pr_number is invalid" unless number.positive?
        data["pr_number"] = number
      end
      if data["pr_url"]
        uri = URI.parse(data["pr_url"].to_s)
        unless uri.scheme == "https" && uri.host == "github.com" &&
               uri.path.match?(%r{\A/[^/]+/[^/]+/pull/\d+\z}) && !uri.userinfo && !uri.query && !uri.fragment
          raise Hive::WorktreeError, "#{FILENAME} pr_url is invalid"
        end
        data["pr_url"] = uri.to_s
      end
      if data["pr_url"] && data["pr_number"]
        expected_url = "https://#{data.fetch('repository')}/pull/#{data.fetch('pr_number')}"
        unless data["pr_url"] == expected_url
          raise Hive::WorktreeError, "#{FILENAME} pr_url contradicts repository or pr_number"
        end
      end
      if data["pr_state"] && !%w[OPEN].include?(data["pr_state"].to_s)
        raise Hive::WorktreeError, "#{FILENAME} pr_state is invalid"
      end
      if data["terminal_outcome"]
        unless TERMINAL_OUTCOMES.include?(data["terminal_outcome"].to_s)
          raise Hive::WorktreeError, "#{FILENAME} terminal_outcome is invalid"
        end
        if data["terminal_outcome"] == "pr-opened"
          missing_pr = REQUIRED_BY_PHASE.fetch("pr_observed").reject { |key| data[key] }
          unless missing_pr.empty?
            raise Hive::WorktreeError, "#{FILENAME} pr-opened terminal is missing: #{missing_pr.join(', ')}"
          end
        elsif data["terminal_outcome"] == "blocked" && !data["error_reason"]
          raise Hive::WorktreeError, "#{FILENAME} blocked terminal requires error_reason"
        end
        if data["terminal_outcome"] != "blocked" && data["error_reason"]
          raise Hive::WorktreeError, "#{FILENAME} non-blocked terminal cannot contain error_reason"
        end
      end
      if data["error_reason"] && !ERROR_REASONS.include?(data["error_reason"].to_s)
        raise Hive::WorktreeError, "#{FILENAME} error_reason is invalid"
      end

      ALL_KEYS.each_with_object({}) do |key, result|
        result[key] = data[key] if data.key?(key)
      end
    rescue ArgumentError, TypeError => e
      raise Hive::WorktreeError, "#{FILENAME} is invalid: #{e.message}"
    end

    def write!(task_folder, attributes, worktree_root:)
      data = validate(attributes, worktree_root: worktree_root)
      Hive::AtomicFile.write(path(task_folder), data.to_yaml, mode: 0o600)
      read(task_folder, worktree_root: worktree_root)
    end
    private_class_method :write!

    def validate_oid!(value, key)
      oid = value.to_s.downcase
      raise Hive::WorktreeError, "#{FILENAME} #{key} is invalid" unless oid.match?(/\A[0-9a-f]{40,64}\z/)

      oid
    end
    private_class_method :validate_oid!

    def validate_time!(value, key)
      text = value.to_s
      parsed = Time.iso8601(text)
      raise Hive::WorktreeError, "#{FILENAME} #{key} must use UTC" unless parsed.utc? && text.end_with?("Z")

      text
    rescue ArgumentError
      raise Hive::WorktreeError, "#{FILENAME} #{key} is invalid"
    end
    private_class_method :validate_time!

    def stringify(value)
      value.to_h.transform_keys(&:to_s)
    end
    private_class_method :stringify

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
