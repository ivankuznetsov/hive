module Hive
  module ClaudeCompletionFallback
    REQUIRED_PHASE_FACTS = {
      artifacts_present: "artifacts_present",
      commit_or_no_change: "commit_or_no_change",
      no_unresolved_escalation: "no_unresolved_escalation",
      worktree_readable: "worktree_readable",
      missing_output_absent: "missing_output_absent"
    }.freeze

    module_function

    def suppress?(evidence:, phase_facts:)
      missing = []
      evidence = symbolize_keys(evidence || {})
      phase_facts = symbolize_keys(phase_facts || {})

      missing << "completion_evidence" if evidence.empty?
      missing << "limit_wall" if limit_wall?(evidence)
      missing << "tmux_readable" if evidence[:tmux_readable] == false || evidence[:session_error].to_s != ""
      missing << "normal_completion" unless normal_completion?(evidence)
      missing << "clean_exit_code" unless clean_exit_code?(evidence)

      REQUIRED_PHASE_FACTS.each do |key, label|
        missing << label unless phase_facts[key] == true
      end

      if missing.empty?
        { suppress: true, reason: "clean_completion_with_phase_evidence", missing: [] }
      else
        { suppress: false, reason: missing.first, missing: missing.uniq }
      end
    end

    def normal_completion?(evidence)
      evidence[:pane_idle] == true || evidence[:process_exited] == true
    end

    def clean_exit_code?(evidence)
      code = evidence[:exit_code]
      code.nil? || code == 0 || code == "0"
    end

    def limit_wall?(evidence)
      reason = evidence[:reason].to_s
      message = evidence[:error_message].to_s
      reason.include?("limit") || message.include?("limits reached")
    end

    def symbolize_keys(hash)
      hash.each_with_object({}) do |(key, value), out|
        out[key.to_sym] = value
      end
    end
  end
end
