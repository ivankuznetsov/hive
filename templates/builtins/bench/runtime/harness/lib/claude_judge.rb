# frozen_string_literal: true

require "open3"
require "json"
require "lib/judge_output"

module HiveBench
  # Production judge_fn for HiveBench::Judge, backed by the local claude CLI
  # (print mode). The user selected claude as the blind judge for the glm-only
  # first pass — a family disjoint from the lone contestant. The Judge class
  # keeps the prompt blind (no agent identity) and verbosity-neutral; this seam
  # only runs the model and parses the rubric's required JSON.
  #
  # `seed` varies nothing in the call (claude print mode is near-deterministic);
  # the Judge still samples N times, so model drift widens the stability interval
  # instead of hiding behind a single point estimate. A garbled or non-numeric
  # response is raised, never coerced into a real score.
  module ClaudeJudge
    Error = JudgeOutput::Error

    # Per-call ceiling (seconds) so a wedged claude CLI can't hang the pass. Set
    # generous (20m) because the judge prompt can carry a large diff + reference.
    DEFAULT_TIMEOUT = 1200

    module_function

    # Returns a judge_fn: ->(prompt:, seed:) => { score:, reason: }.
    # model: nil uses whatever the operator's claude CLI defaults to; pass
    # --judge-model to pin it. The `timeout` binary bounds a hung call.
    def judge_fn(bin: "claude", model: nil, timeout_s: DEFAULT_TIMEOUT)
      lambda do |prompt:, seed:|
        _ = seed
        argv = ["timeout", timeout_s.to_s, bin, "-p"]
        argv += ["--model", model] if model
        out, err, status = Open3.capture3(*argv, stdin_data: prompt.to_s)
        raise Error, "claude judge timed out after #{timeout_s}s" if status.exitstatus == 124

        unless status.success?
          detail = err.strip
          detail = out.strip if detail.empty?
          raise Error, "claude judge exited #{status.exitstatus}: #{detail[0, 300]}"
        end

        JudgeOutput.parse_score(out)
      end
    end

    # Kept for the existing unit tests / callers; delegates to the shared parser.
    def parse_score(text) = JudgeOutput.parse_score(text)
  end
end
