module HiveLiveAgentProof
  module OpenClawCreatorProof
    class EvidenceDocument
      attr_reader :data, :process_records, :secret_findings

      def initialize(candidate_sha:, model:, credential:)
        @credential = credential.to_s
        @process_records = []
        @secret_findings = Set.new
        safe_candidate = SAFE_SHA.match?(candidate_sha) ? candidate_sha : "unresolved"
        @data = {
          "schema" => EVIDENCE_SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "platform" => "openclaw",
          "candidate_sha" => safe_candidate,
          "result" => "failed",
          "phase" => "initializing",
          "reason" => "not_started",
          "provider" => {
            "name" => "unresolved",
            "model" => redact(model),
            "credential_environment" => nil
          },
          "openclaw_package" => {
            "version" => OPENCLAW_VERSION,
            "integrity" => OPENCLAW_INTEGRITY,
            "lock_sha256" => OPENCLAW_LOCK_SHA256,
            "package_count" => OPENCLAW_LOCK_PACKAGE_COUNT,
            "verified" => false
          },
          "executables" => {
            "openclaw" => unresolved_executable,
            "candidate" => unresolved_executable,
            "audit_gateway" => unresolved_executable(nil)
          },
          "processes" => [],
          "teardown" => {
            "status" => "not_started",
            "term_sent" => false,
            "kill_sent" => false,
            "reaped" => true,
            "descendants" => "not_checked",
            "containment" => "not_started",
            "teardown_authority" => "not_started",
            "root_loss_guarantee" => WORKFLOW_CREATOR_ROOT_LOSS_GUARANTEE
          },
          "cleanup" => {
            "status" => "not_started",
            "root_removed" => false
          }
        }
      end

      def phase=(value)
        @data["phase"] = value.to_s
      end

      def provider=(value)
        @data["provider"] = value
      end

      def set_executable(name, record)
        @data.fetch("executables")[name.to_s] = record
      end

      def openclaw_package_verified!(receipt)
        package = receipt.fetch("package")
        lock = receipt.fetch("lock")
        @data["openclaw_package"] = {
          "version" => package.fetch("version"),
          "integrity" => package.fetch("integrity"),
          "lock_sha256" => lock.fetch("sha256"),
          "package_count" => lock.fetch("package_count"),
          "receipt_sha256" => receipt.fetch("receipt_sha256"),
          "verified" => true
        }
      end

      def merge!(values)
        @data.merge!(values)
      end

      def record_process(result, label: nil)
        record = result.fetch("record")
        record = record.merge("label" => label) if label
        @process_records << record
        @secret_findings.merge(result.fetch("secret_findings"))
      end

      def failure(failure)
        @data["result"] = "failed"
        @data["phase"] = failure.phase
        @data["reason"] = failure.reason
        @data["detail"] = redact(failure.message)
        @data["failure_receipt"] = failure.evidence if failure.evidence
        @data
      end

      def cleanup=(value)
        @data["cleanup"] = value
      end

      def finalize_teardown
        @data["processes"] = @process_records
        teardowns = @process_records.filter_map { |record| record["teardown"] }
        @data["teardown"] = {
          "status" => teardowns.all? { |row| row["status"] == "passed" } ? "passed" : "failed",
          "term_sent" => teardowns.any? { |row| row["term_sent"] },
          "kill_sent" => teardowns.any? { |row| row["kill_sent"] },
          "reaped" => teardowns.all? { |row| row["reaped"] },
          "descendants" =>
            teardowns.all? { |row| row["descendants"] == "none" } ? "none" : "not_checked",
          "containment" =>
            teardowns.all? {
              |row| row["containment"] == WORKFLOW_CREATOR_PROCESS_CONTAINMENT
            } ? WORKFLOW_CREATOR_PROCESS_CONTAINMENT : "not_started",
          "teardown_authority" =>
            teardowns.all? {
              |row| row["teardown_authority"] == WORKFLOW_CREATOR_TEARDOWN_AUTHORITY
            } ? WORKFLOW_CREATOR_TEARDOWN_AUTHORITY : "not_started",
          "root_loss_guarantee" => WORKFLOW_CREATOR_ROOT_LOSS_GUARANTEE
        }
        @data["teardown"]["status"] = "not_started" if teardowns.empty?
      end

      def finalize_secret_scan
        findings = @secret_findings.to_a
        findings.concat(
          HiveLiveAgentProof.secret_findings(
            JSON.generate(@data),
            exact_secrets: [ @credential ]
          )
        )
        @data["secret_scan"] = {
          "status" => findings.empty? ? "passed" : "failed",
          "scanner" => "hive-live-agent-proof/v1"
        }
        return if findings.empty?

        failure(
          Failure.new(
            phase: "secret_scan",
            reason: "secret_material_detected",
            detail: "proof evidence or raw output contained credential material"
          )
        )
        sanitize_sensitive_data!
      end

      def write(path)
        return if path.to_s.empty?

        sanitize_sensitive_data!
        if sensitive_findings(@data).any?
          replace_with_minimal_safe_failure!
        end
        HiveLiveAgentProof.write_json(path, @data)
      end

      private

      def unresolved_executable(configured = nil)
        {
          "configured_path" => configured.to_s.empty? ? nil : configured.to_s,
          "realpath" => nil,
          "sha256" => nil
        }
      end

      def redact(value)
        redacted = value.to_s.dup
        redacted.gsub!(@credential, "[REDACTED]") unless @credential.empty?
        SECRET_PATTERNS.each { |pattern| redacted.gsub!(pattern, "[REDACTED]") }
        redacted.byteslice(0, DETAIL_LIMIT).to_s.scrub
      end

      def sanitize_sensitive_data!
        sanitized = deep_redact(@data)
        @data.clear
        @data.merge!(sanitized)
      end

      def deep_redact(value)
        case value
        when Hash
          value.to_h { |key, nested| [ key, deep_redact(nested) ] }
        when Array
          value.map { |nested| deep_redact(nested) }
        when String
          redact(value)
        else
          value
        end
      end

      def sensitive_findings(value)
        HiveLiveAgentProof.secret_findings(
          JSON.generate(value),
          exact_secrets: [ @credential ]
        )
      end

      def replace_with_minimal_safe_failure!
        safe_candidate = @data["candidate_sha"]
        @data.clear
        @data.merge!(
          "schema" => EVIDENCE_SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "platform" => "openclaw",
          "candidate_sha" => SAFE_SHA.match?(safe_candidate.to_s) ? safe_candidate : "unresolved",
          "result" => "failed",
          "phase" => "secret_scan",
          "reason" => "secret_material_detected",
          "detail" => "unsafe proof evidence was replaced before persistence",
          "provider" => {
            "name" => "unresolved",
            "model" => "[REDACTED]",
            "credential_environment" => nil
          },
          "openclaw_package" => {
            "version" => OPENCLAW_VERSION,
            "integrity" => OPENCLAW_INTEGRITY,
            "lock_sha256" => OPENCLAW_LOCK_SHA256,
            "package_count" => OPENCLAW_LOCK_PACKAGE_COUNT,
            "verified" => false
          },
          "executables" => {
            "openclaw" => unresolved_executable(nil),
            "candidate" => unresolved_executable(nil),
            "audit_gateway" => unresolved_executable(nil)
          },
          "processes" => [],
          "teardown" => {
            "status" => "not_started",
            "term_sent" => false,
            "kill_sent" => false,
            "reaped" => true,
            "descendants" => "not_checked",
            "containment" => "not_started",
            "teardown_authority" => "not_started",
            "root_loss_guarantee" => WORKFLOW_CREATOR_ROOT_LOSS_GUARANTEE
          },
          "cleanup" => {
            "status" => "not_started",
            "root_removed" => false
          },
          "secret_scan" => {
            "status" => "failed",
            "scanner" => "hive-live-agent-proof/v1"
          }
        )
      end
    end
  end
end
