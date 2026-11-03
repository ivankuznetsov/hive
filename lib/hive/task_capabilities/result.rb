require "hive/task_capabilities/plan"
require "hive/agent_git_gate"

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
        invalid!("invalid verification result schema") unless data.is_a?(Hash) && data.keys.sort == KEYS.sort && data["schema_version"] == 1
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
        digest("check" => check, "binding" => binding.slice("id", "stage", "actor", "actor_route", "actor_fingerprint", "skill_identity", "permissions", "targets", "budget_usd", "timeout_sec", "approval_reference"))
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
