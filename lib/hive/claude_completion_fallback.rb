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
      # A live tmux session must be PROVEN before suppression (R4 / plan U3
      # "unknown or ambiguous evidence ⇒ suppress:false"). A clean
      # `session_exists? == false` reports `session_alive: false` with an
      # empty `session_error`, which the tmux_readable/session_error guard
      # above misses — reject it here. `nil` ("unknown": no runner, or the
      # probe was never run) is treated the same way: the docs require a
      # live tmux session, so anything short of an affirmative `true` blocks.
      missing << "session_alive" unless evidence[:session_alive] == true
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
      # On the persistent tmux REPL the recorded pid is the long-lived pane
      # process, so `process_exited == true` does NOT mean a clean turn-end —
      # it means the REPL itself died (a crash), exactly the case R3 keeps
      # terminal ("normal completion rather than crash"). Only an idle ready
      # prompt (`pane_idle == true`) is affirmative evidence the turn ended
      # cleanly; a dead process must fall through to REVIEW_ERROR.
      evidence[:pane_idle] == true
    end

    def clean_exit_code?(evidence)
      # `exit_code` is advisory-only on the tmux path (always nil — see
      # ClaudeLauncher#completion_evidence), so `nil` reads as "no
      # objection". An integer code is still honored for any future caller
      # that supplies a real one; a stringified "0" was never produced and
      # the dead branch has been dropped.
      code = evidence[:exit_code]
      code.nil? || code == 0
    end

    def limit_wall?(evidence)
      reason = evidence[:reason].to_s
      # `error_message` is FORWARD-COMPAT only: the current tmux launcher
      # path (ClaudeLauncher#completion_evidence) sets `reason`/`session_error`
      # but never an `error_message` key, so this branch is dead today. It
      # stays for any future caller that supplies a richer evidence hash, in
      # the same spirit as the clean_exit_code?/missing_output_error? docs.
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
