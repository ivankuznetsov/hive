require "fileutils"

module Hive
  module Stages
    module Review
      # Review-loop convergence rules shared by the reviewer and triage
      # prompts. Without them every fix commit became fresh review surface:
      # triage accepted every finding, later passes kept surfacing adjacent
      # edge cases and release-evidence gates, and loops ended only at the
      # pass cap (REVIEW_STALE final_fix_unverified). The rules keep pass 1
      # broad and make later passes converge:
      #
      # - Release-evidence gates (CI signoff, pushed-head state, acceptance
      #   or smoke re-runs on the current commit) are never code findings;
      #   the CI and finalize gates own them.
      # - From `review.severity_gate_from_pass` (default 2) only High
      #   findings with concrete evidence are fixed; Medium/Low/Nit findings
      #   are recorded as DEFERRED, which neither triggers a fix pass nor
      #   blocks completion.
      # - A verify-only pass (beyond `review.max_passes`) reports only
      #   unresolved or regressed findings; anything new is out of scope.
      module Convergence
        DEFERRED_LABEL = "DEFERRED".freeze

        module_function

        def severity_gate_from_pass(cfg)
          value = cfg.dig("review", "severity_gate_from_pass")
          value.is_a?(Integer) && value.positive? ? value : nil
        end

        def severity_gated?(cfg, pass)
          gate = severity_gate_from_pass(cfg)
          !gate.nil? && pass.to_i >= gate
        end

        def verify_only?(cfg, pass)
          max_passes = cfg.dig("review", "max_passes")
          max_passes.is_a?(Integer) && pass.to_i > max_passes
        end

        def reviewer_section(cfg, pass)
          lines = [ "Review scope rules (pass #{pass}):", "" ]
          lines << PROCESS_EVIDENCE_RULE
          if verify_only?(cfg, pass)
            lines << "- This is a VERIFY-ONLY pass. Report only findings that are still " \
                     "unresolved from earlier passes, or regressions introduced by the latest " \
                     "fix commits. Do not report new findings about code that the latest fix " \
                     "commits did not change."
          elsif severity_gated?(cfg, pass)
            lines << "- This is a later review pass. Prioritize regressions and High-severity " \
                     "defects with concrete evidence (a reproduction, a failing input, or the " \
                     "exact code path). Do not widen scope with speculative hardening."
          end
          lines.join("\n") + "\n"
        end

        def triage_section(cfg, pass)
          lines = [ "## Convergence rules (pass #{pass})", "" ]
          lines << "These rules take precedence over the bias rules below."
          lines << ""
          lines << "- **Release-evidence gates are RESOLVED/NO-FIX.** Findings asking to sign off " \
                   "CI, push or sign off a specific head, or re-run acceptance or smoke on the " \
                   "current commit are not code findings; the CI and finalize gates own them. " \
                   "Reason: `release-evidence gate owned by CI/finalize`."
          lines << "- **Reject on merit with RESOLVED/NO-FIX and a one-line reason** when the " \
                   "finding is outside the task's stated requirements or plan scope, needs " \
                   "implausible input with no realistic source (adversarial sizes or encodings, " \
                   "hostile local files the user controls anyway), or has well under ~1% " \
                   "likelihood of mattering. NO-FIX is a decision, not only deduplication."
          if verify_only?(cfg, pass)
            lines << "- **Verify-only pass.** Only findings that are unresolved from earlier " \
                     "passes or regressions introduced by the latest fix commits may be " \
                     "AUTO-FIX or ESCALATE. Mark every other finding RESOLVED/NO-FIX with " \
                     "reason `out of verify-only scope`."
          end
          if severity_gated?(cfg, pass)
            lines << "- **Severity gate.** Only High-severity findings with concrete evidence " \
                     "(a reproduction, failing input, or exact code path) may be AUTO-FIX. " \
                     "Rewrite Medium, Low and Nit findings as " \
                     "`- [x] #{DEFERRED_LABEL}: <finding> <!-- triage: <one-phrase reason> -->`. " \
                     "Deferred findings are not fixed in this review; they are collected for at " \
                     "most one follow-up task."
          end
          lines.join("\n") + "\n"
        end

        DEFERRED_LINE_RE = /\A\s*-\s+\[x\]\s+DEFERRED:\s+(.*?)(?:\s*<!--.*-->)?\s*\z/i.freeze
        DEFERRED_SUMMARY = "deferred-findings.md".freeze

        # Collect every DEFERRED finding across passes into one summary the
        # operator can turn into at most one follow-up task. Returns the
        # number of findings written; writes nothing when there are none.
        def write_deferred_summary!(task_folder)
          reviews = File.join(task_folder, "reviews")
          rows = Dir[File.join(reviews, "*-[0-9][0-9].md")].sort.flat_map do |path|
            File.readlines(path).filter_map do |line|
              match = DEFERRED_LINE_RE.match(line)
              "- #{match[1].strip} (#{File.basename(path, '.md')})" if match
            end
          end
          summary = File.join(reviews, DEFERRED_SUMMARY)
          if rows.empty?
            FileUtils.rm_f(summary)
            return 0
          end

          File.write(summary, <<~MD)
            # Deferred review findings

            These findings were deferred by the review severity gate and were not fixed.
            File them as at most one follow-up task. If this task is itself a review
            follow-up, do not file another follow-up: record them in `wiki/gaps.md` or
            the pull request description instead.

            #{rows.join("\n")}
          MD
          rows.length
        end

        PROCESS_EVIDENCE_RULE =
          "- Do not report release-evidence gates as findings: CI signoff, pushed-head or " \
          "exact-commit state, or re-running acceptance or smoke on the current commit. CI " \
          "and finalize own those gates; report only defects in the code and docs under " \
          "review.".freeze
      end
    end
  end
end
