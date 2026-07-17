require "hive/diagnostic_evidence"

module Hive
  # Canonical terminal diagnostics. This registry deliberately owns no retry
  # eligibility, timing, counter, suppression, or dispatch fields: every entry
  # routes to the one RetryCoordinator policy boundary.
  module TerminalErrorRegistry
    class InvalidDeclaration < Hive::Error; end

    ROUTE = "coordinator".freeze
    FORBIDDEN_FIELDS = %w[
      retry retryable eligible eligibility delay backoff schedule counter budget
      max_retries provider_override stage_override suppress dispatch quarantine
    ].freeze
    Entry = Data.define(:code, :extractor, :guidance, :route) do
      def extract(payload)
        extractor.call(payload)
      end
    end

    # Exact marker reasons currently emitted by terminal agent/stage paths,
    # plus canonical families used when durable ownership supplies the signal.
    CODES = %w[
      unknown agent_died agent_orphaned timeout codex_auth provider_auth provider_failure
      review_failed pr_open_failed pr_rebase_failed pr_push_failed finalize_failed
      attempt_lost owner_identity_mismatch owner_gone legacy_owner_gone launch_timeout
      first_heartbeat_timeout successor_launch_failed
      no_marker_no_exit_code exit_code limits_reached tmux_session_terminated
      tmux_pane_unreadable permission_config_error tmux_unavailable claude_launch_failed
      agent_preflight_failed instruction_unreadable implementer_failed runner_exception
      council_failed council_io_error missing_input
      open_pr_tampered open_pr_marker_missing_complete open_pr_marker_missing_url
      open_pr_not_draft open_pr_url_mismatch open_pr_lookup_failed
      secret_scan_fetch_failed secret_in_pr_body
      finalize_tampered missing_pr_md missing_pr_url git_status_failed
      ensure_clean_on_exit_failed unpushed_commits finalize_pr_url_tampered
      finalize_marker_not_ready gh_pr_ready_failed worktree_git_failed
      reviewer_partial_failure review_agent_died review_orphaned ci_unrunnable
      browser_unexpected fix_tampered triage_tampered fix_status_check_failed
      fix_auto_commit_scope_failed fix_auto_commit_sign_policy_failed
      fix_auto_commit_signing_failed malformed_marker_matches
      agent_failure agent_limit approval_dirty_worktree approval_head_mismatch
      branch_mismatch config_error deadline_without_stop_hook dirty_worktree
      fix_dirty_worktree fix_guardrail head_not_descendant max_rounds
      missing_research_output needs_revision no_worktree_changes resume_no_findings
      token_limit turn_ended_without_stop_hook turn_limit wall_clock
    ].freeze

    AUTH_SIGNATURE = /(?:401|unauthori[sz]ed|missing\s+(?:bearer|basic)\s+auth|codex.*auth|mcp.*auth)/i.freeze

    module_function

    def fetch(code)
      entries.fetch(code.to_s) { entries.fetch("unknown") }
    end

    def codes = entries.keys.freeze

    def normalize(code, payload = {})
      raw = code.to_s.strip
      text = flatten_text(payload)
      return "codex_auth" if %w[implementer_failed exit_code provider_auth].include?(raw) && text.match?(AUTH_SIGNATURE)
      return raw if entries.key?(raw)

      "unknown"
    end

    def diagnose(code:, payload: {})
      canonical = normalize(code, payload)
      entry = fetch(canonical)
      {
        "code" => entry.code,
        "route" => entry.route,
        "guidance" => entry.guidance,
        "evidence" => entry.extract(payload)
      }
    end

    def validate_declaration!(declaration)
      unless declaration.is_a?(Hash)
        raise InvalidDeclaration, "terminal error declaration must be an object"
      end
      stringified = declaration.transform_keys(&:to_s)
      forbidden = stringified.keys & FORBIDDEN_FIELDS
      raise InvalidDeclaration, "retry-policy fields are forbidden: #{forbidden.join(', ')}" unless forbidden.empty?

      code = stringified["code"]
      extractor = stringified["extractor"]
      guidance = stringified["guidance"]
      route = stringified["route"]
      raise InvalidDeclaration, "terminal error code is required" if code.to_s.strip.empty?
      raise InvalidDeclaration, "bounded evidence extractor is required" unless extractor.respond_to?(:call)
      raise InvalidDeclaration, "repair guidance is required" if guidance.to_s.strip.empty?
      raise InvalidDeclaration, "terminal errors must route to coordinator" unless route.to_s == ROUTE

      sample = extractor.call({ "message" => "sample" })
      unless sample.is_a?(Array) && sample.length <= Hive::DiagnosticEvidence::RETRY_EVIDENCE_MAX_ENTRIES
        raise InvalidDeclaration, "evidence extractor must return a bounded array"
      end
      true
    end

    def entries
      @entries ||= CODES.to_h do |code|
        declaration = {
          "code" => code,
          "extractor" => ->(payload) { Hive::DiagnosticEvidence.sanitize_retry(payload) },
          "guidance" => guidance_for(code),
          "route" => ROUTE
        }
        validate_declaration!(declaration)
        [ code, Entry.new(**declaration.transform_keys(&:to_sym)) ]
      end.freeze
    end

    def guidance_for(code)
      case code
      when "codex_auth", "provider_auth"
        "Repair the daemon's current provider or MCP authentication, then use an audited retry repair/reset."
      when "agent_died", "attempt_lost", "owner_gone", "owner_identity_mismatch", "legacy_owner_gone"
        "Inspect the failed attempt log and preserved worktree before allowing the coordinator to relaunch it."
      when "timeout", "launch_timeout", "first_heartbeat_timeout"
        "Inspect the attempt deadline and command log; repair the underlying stall before resetting the cooldown."
      when /secret/
        "Remove the secret from the proposed change and rotate it if it may have been exposed."
      when /pr_|open_pr|unpushed|gh_pr/
        "Repair GitHub, branch, rebase, or push state; preserve the task worktree and then reset through the coordinator."
      when /review|fix_|triage|ci_|browser/
        "Inspect review evidence and repair the failing check or worktree state before an audited reset."
      else
        "Inspect the sanitized evidence, repair the terminal condition, and use the coordinator's guarded repair action if immediate retry is required."
      end
    end

    def flatten_text(value)
      case value
      when Hash then value.flat_map { |key, child| [ key, flatten_text(child) ] }.join(" ")
      when Array then value.map { |child| flatten_text(child) }.join(" ")
      else value.to_s
      end
    end

    private_class_method :entries, :guidance_for, :flatten_text
  end
end
