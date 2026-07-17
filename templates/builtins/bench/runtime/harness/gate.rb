# frozen_string_literal: true

require "yaml"
require "lib/git_restore"
require "lib/test_result_parser"

module HiveBench
  # Scoring tier 1 — the objective floor. Restores a clean repo at base, applies
  # the candidate's persisted diff (NOT the candidate's possibly-dirty worktree —
  # generation and evaluation are separate), runs install + test commands in the
  # no-network gate container, and passes the cell iff the task's FAIL_TO_PASS
  # tests flipped to passing and its PASS_TO_PASS tests stayed green
  # (SWE-bench's criterion).
  #
  # Tasks whose gate is uncurated or has no FAIL_TO_PASS are `:no_gate` and land
  # in the "judged" subset (scored by tiers 2–3 only). The gated:judged split is
  # what the leaderboard publishes so the "objective floor" isn't overstated.
  class Gate
    Result = Data.define(:status, :subset, :reason, :details) do
      def gated? = subset == "gated"
    end

    # exec: ->(cmd:, work_dir:) => { output: String, ok: Boolean }
    #   In production this runs the command inside the `--network none` runner
    #   (isolation.sh gate mode). Injected as a seam so tests run offline.
    def initialize(exec:, restorer: GitRestore.new, parser: TestResultParser)
      @exec = exec
      @restorer = restorer
      @parser = parser
    end

    # entry: loaded manifest hash (+ entry_dir, checkout_source).
    # gate_spec: the parsed gate/gate.yml.
    # candidate_patch: the diff string to score.
    def call(entry:, gate_spec:, candidate_patch:, work_dir:)
      return judged("gate not curated") if gate_spec["needs_curation"]

      f2p = Array(gate_spec["fail_to_pass"])
      p2p = Array(gate_spec["pass_to_pass"])
      return judged("no FAIL_TO_PASS tests declared") if f2p.empty?

      @restorer.restore(source: entry.fetch("checkout_source"),
                        base_commit: entry.dig("source", "base_commit"), into: work_dir)
      return error("candidate diff did not apply at base") unless @restorer.apply(work_dir: work_dir, patch: candidate_patch.to_s)

      # SWE-bench-style held-out tests: the REFERENCE's test files overlay the
      # candidate's diff (the gate's F2P names come from the reference, so the
      # reference tests must be present). A failed overlay is NOT an immediate
      # error: the candidate may already carry those exact files (the reference
      # itself does — the validator's reproducibility run) or same-path files
      # of its own. The run proceeds; if the F2P names aren't positively
      # observed afterwards, classify() errors the cell anyway.
      overlay = "applied"
      if (tests_rel = gate_spec["tests_patch"])
        tests_patch = File.read(File.join(entry.fetch("entry_dir"), tests_rel))
        overlay = @restorer.apply(work_dir: work_dir, patch: tests_patch) ? "applied" : "conflicted (candidate supplies same-path tests)"
      end

      result = run_gate(gate_spec, work_dir, f2p, p2p)
      result.details["tests_overlay"] = overlay if gate_spec["tests_patch"]
      result
    end

    private

    def run_gate(gate_spec, work_dir, f2p, p2p)
      if (install = gate_spec["install_cmd"])
        ires = @exec.call(cmd: install, work_dir: work_dir)
        return error("install failed: #{install}") unless ires[:ok]
      end

      tres = @exec.call(cmd: gate_spec.fetch("test_cmd"), work_dir: work_dir)
      parsed = @parser.parse(tres[:output])
      return error("test command produced no parseable result") unless parsed.ran

      classify(parsed, f2p, p2p)
    end

    def classify(parsed, f2p, p2p)
      # Every declared gate test must be POSITIVELY observed in the run (verbose
      # per-test line or failure block). Absence is never a pass: a FAIL_TO_PASS
      # test that never ran (typo, deleted, not collected) or a PASS_TO_PASS
      # guard the candidate deleted must error the cell, not clear the floor.
      # Curation rule: every gated test_cmd emits per-test results (TESTOPTS=-v).
      unobserved = (f2p + p2p).reject { |name| @parser.observed?(parsed, name) }
      unless unobserved.empty?
        return error("gate tests not observed in run (test_cmd must emit per-test " \
                     "results, e.g. TESTOPTS=-v): #{unobserved.join(", ")}")
      end

      f2p_ok = f2p.all? { |name| @parser.test_outcome(parsed, name) }
      p2p_ok = p2p.all? { |name| @parser.test_outcome(parsed, name) }

      if f2p_ok && p2p_ok
        gated(:pass, "FAIL_TO_PASS flipped and PASS_TO_PASS held")
      else
        gated(:fail, failure_reason(f2p_ok, p2p_ok))
      end
    end

    # Only called when the run is not a pass, so at least one of the two is
    # false. f2p failure takes precedence; otherwise it's a p2p regression.
    # Total by construction — never returns nil.
    def failure_reason(f2p_ok, _p2p_ok)
      return "FAIL_TO_PASS tests did not all pass" unless f2p_ok

      "PASS_TO_PASS regression: a guard test broke"
    end

    def gated(status, reason)
      Result.new(status: status, subset: "gated", reason: reason, details: {})
    end

    def judged(reason)
      Result.new(status: :no_gate, subset: "judged", reason: reason, details: {})
    end

    def error(reason)
      Result.new(status: :error, subset: "gated", reason: reason, details: {})
    end
  end
end
