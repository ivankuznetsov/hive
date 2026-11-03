require "hive/task_capabilities/plan"
require "hive/agent_git_gate"
require "hive/git_ops"
require "open3"

module Hive
  module TaskCapabilities
    # Controller-accepted check observations, including unsuccessful runs, are
    # immutable. A stage marker or an agent's verdict is never a result.
    class Result
      STATES = %w[pending running passed failed blocked not-applicable stale].freeze
      KEYS = %w[schema_version task execution_plan_digest capability_id check_id parent_attempt_id spawn_id evaluated_sha check_digest environment_digest kind claim runner state applicability evidence findings reason].freeze
      IDENTITY_KEYS = %w[task execution_plan_digest capability_id check_id parent_attempt_id evaluated_sha check_digest environment_digest].freeze
      class Invalid < Hive::Error; end
      attr_reader :data

      def initialize(value)
        @data = Plan.redact(Hive::WorkflowPackage::CanonicalJSON.normalize(value))
        invalid!("invalid verification result schema") unless data.is_a?(Hash) && (data.keys - %w[task_delta observed_route]).sort == KEYS.sort && data["schema_version"] == 1
        invalid!("invalid verification result task") unless data["task"].is_a?(Hash) && data["task"].keys.sort == %w[id slug workflow]
        %w[capability_id check_id].each { |key| invalid!("invalid verification #{key}") unless Definition::ID.match?(data[key].to_s) }
        %w[execution_plan_digest check_digest environment_digest].each { |key| invalid!("invalid verification #{key}") unless Plan::DIGEST.match?(data[key].to_s) }
        invalid!("invalid evaluated Git revision") unless Hive::AgentGitGate::OID.match?(data["evaluated_sha"].to_s)
        text!(data["parent_attempt_id"], "parent attempt")
        text!(data["spawn_id"], "spawn correlation") unless data["spawn_id"].nil?
        text!(data["claim"], "behavior claim")
        invalid!("invalid verification runner or kind") unless data["runner"].is_a?(Hash) && Definition::CHECK_KINDS.include?(data["kind"])
        invalid!("invalid verification state") unless STATES.include?(data["state"])
        invalid!("invalid verification evidence or findings") unless data["evidence"].is_a?(Array) && data["findings"].is_a?(Array)
        invalid!("invalid applicability evidence") unless data["applicability"].is_a?(Hash)
        if data["task_delta"]
          delta = data["task_delta"]
          unless delta.is_a?(Hash) && delta.keys.sort == %w[base base_blobs base_tree delta_digest patch_ids target_ref target_tree] &&
              %w[base base_tree target_tree].all? { |key| Hive::AgentGitGate::OID.match?(delta[key].to_s) } && Plan::DIGEST.match?(delta["delta_digest"].to_s) &&
              delta["patch_ids"].is_a?(Array) && delta["patch_ids"].all? { |id| Hive::AgentGitGate::OID.match?(id.to_s) } &&
              delta["target_ref"].is_a?(String) && !delta["target_ref"].empty? && delta["base_blobs"].is_a?(Hash) && delta["base_blobs"].all? { |path, bytes| path.is_a?(String) && bytes.is_a?(String) }
            invalid!("invalid complete task delta identity")
          end
        end
        invalid!("invalid observed actor route") if data.key?("observed_route") && !data["observed_route"].is_a?(Hash)
        data["evidence"].each { |entry| validate_evidence!(entry) }
        data["findings"].each { |finding| validate_finding!(finding) }
        ids = data["findings"].map { |finding| finding.fetch("id") }
        invalid!("duplicate finding IDs") unless ids.uniq == ids
        case data["state"]
        when "passed", "failed"
          invalid!("completed verification requires evidence") if data["evidence"].empty?
          invalid!("failed verification requires actionable findings") if data["state"] == "failed" && data["findings"].empty?
          invalid!("passed verification cannot contain findings") if data["state"] == "passed" && !data["findings"].empty?
          data["evidence"].select { |entry| entry["kind"] == "command" }.each do |entry|
            invalid!("command exit contradicts verification state") unless (entry["exit_status"] == 0) == (data["state"] == "passed")
          end
        when "not-applicable"
          text!(data.dig("applicability", "reason"), "not-applicable reason")
          invalid!("not-applicable requires applicability evidence") if data["evidence"].empty?
        else
          text!(data["reason"], "verification reason")
        end
        Definition.deep_freeze(data)
        freeze
      rescue Hive::ConfigError => error
        raise Invalid, error.message
      end

      def to_h = data
      def state = data.fetch("state")
      def digest = self.class.digest(data)
      def self.digest(value) = ::Digest::SHA256.hexdigest(Hive::WorkflowPackage::CanonicalJSON.generate(value))

      def self.check_digest(binding, check)
        digest("check" => check, "binding" => binding.slice("id", "stage", "actor", "actor_route", "actor_fingerprint", "actor_binary", "skill_identity", "permissions", "targets", "budget_usd", "timeout_sec", "approval_reference"))
      end

      # Complete ordered task delta, including binary bytes and the relevant
      # base blobs. Merges, empty commits and unreadable history are ambiguous.
      def self.task_delta(worktree, sha:, target_branch: nil)
        git = lambda do |*args, input: nil|
          out, err, status = Open3.capture3("git", "-C", worktree, *args, stdin_data: input.to_s)
          raise Invalid, "task delta unavailable: #{err.strip}" unless status.success?
          out
        end
        origin = Open3.capture3("git", "-C", worktree, "remote", "get-url", "origin").last.success?
        repository = Hive::GitOps.new(worktree)
        branch = target_branch || (origin ? repository.origin_default_branch : repository.default_branch)
        return nil unless branch
        Hive::GitRef.validate_branch_name(branch)
        reference = origin ? "refs/remotes/origin/#{branch}" : "refs/heads/#{branch}"
        return nil unless Open3.capture3("git", "-C", worktree, "rev-parse", "--verify", reference).last.success?
        base = git.call("merge-base", reference, sha).strip
        commits = git.call("rev-list", "--reverse", "#{base}..#{sha}").lines.map(&:strip)
        merges = !git.call("rev-list", "--merges", "#{base}..#{sha}").empty?
        patches = (merges ? [] : commits).map do |oid|
          patch = git.call("show", "--format=", "--binary", "--full-index", oid)
          git.call("patch-id", "--stable", input: patch).split.first
        end
        patches = [] if patches.any?(&:nil?)
        paths = git.call("diff", "--name-only", "-z", base, sha).split("\0").sort
        base_blobs = paths.to_h { |path| [ path, git.call("ls-tree", "-z", base, "--", path) ] }
        delta = git.call("diff", "--binary", "--full-index", base, sha)
        { "base" => base, "base_tree" => git.call("rev-parse", "#{base}^{tree}").strip,
          "target_ref" => reference, "target_tree" => git.call("rev-parse", "#{reference}^{tree}").strip, "patch_ids" => patches, "delta_digest" => ::Digest::SHA256.hexdigest(delta.b), "base_blobs" => base_blobs }
      rescue Hive::Error, SystemCallError, TypeError, ArgumentError
        nil
      end

      def self.equivalent_delta?(old, current)
        return false unless old.is_a?(Hash) && current.is_a?(Hash) && old.keys.sort == %w[base base_blobs base_tree delta_digest patch_ids target_ref target_tree] && current.keys.sort == old.keys.sort
        same_base_context?(old, current) && !old["patch_ids"].empty? && old["patch_ids"] == current["patch_ids"] && old["delta_digest"] == current["delta_digest"] && old["base_blobs"] == current["base_blobs"]
      end

      def self.same_base_context?(old, current)
        old.is_a?(Hash) && current.is_a?(Hash) && %w[base_tree target_ref target_tree].all? { |key| old[key] && old[key] == current[key] }
      end

      def self.command(identity, exit_status:, output:)
        output = Hive::SecretPatterns.redact(output)
        evidence = [ { "kind" => "command", "evaluated_sha" => identity.fetch("evaluated_sha"),
          "exit_status" => exit_status, "output" => output, "sha256" => ::Digest::SHA256.hexdigest(output) } ]
        findings = exit_status.zero? ? [] : [ { "id" => "#{identity.fetch('capability_id')}:#{identity.fetch('check_id')}:command-failed",
          "summary" => "#{identity.fetch('claim')} failed", "details" => "Check exited #{exit_status}. #{output}".byteslice(0, 12_000).scrub, "severity" => "medium" } ]
        new(identity.merge("state" => exit_status.zero? ? "passed" : "failed", "reason" => nil,
          "evidence" => evidence, "findings" => findings, "applicability" => {}))
      end

      private

      def invalid!(message) = raise(Invalid, message)
      def text!(value, label)
        invalid!("#{label} must be nonempty bounded text") unless value.is_a?(String) && !value.strip.empty? && value.bytesize <= 16_384 && !value.include?("\0")
      end

      def validate_evidence!(entry)
        invalid!("invalid verification evidence") unless entry.is_a?(Hash) && entry["evaluated_sha"] == data["evaluated_sha"]
        case entry["kind"]
        when "command"
          invalid!("invalid command evidence") unless entry.keys.sort == %w[evaluated_sha exit_status kind output sha256] && entry["exit_status"].is_a?(Integer) && entry["exit_status"] >= 0 && entry["output"].is_a?(String) && entry["sha256"] == ::Digest::SHA256.hexdigest(entry["output"])
        when "outcome"
          invalid!("invalid outcome evidence") unless entry.keys.sort == %w[evaluated_sha kind proof] && entry["proof"].is_a?(Hash)
        else
          invalid!("unsupported verification evidence kind")
        end
      end

      def validate_finding!(finding)
        invalid!("invalid verification finding") unless finding.is_a?(Hash) && finding.keys.sort == %w[details id severity summary] && finding["id"].to_s.match?(/\A[a-z0-9][a-z0-9:._-]{0,191}\z/) && %w[high medium low].include?(finding["severity"])
        %w[summary details].each { |key| text!(finding[key], "finding #{key}") }
      end
    end
  end
end
