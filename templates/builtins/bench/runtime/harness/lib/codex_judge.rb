# frozen_string_literal: true

require "open3"
require "json"
require "lib/judge_output"
require "lib/agent_limit"

module HiveBench
  # Judge_fn backed by the codex CLI (exec mode) — rides the operator's
  # ChatGPT subscription, so a judged pass costs no API balance (maintainer
  # decision 2026-07-09: judge slate = fable-5 + gpt-5.6-sol@xhigh via codex).
  #
  # The prompt arrives on stdin (`codex exec -`): judge prompts carry a full
  # diff + reference and overflow argv limits. `--skip-git-repo-check` because
  # the judge runs from wherever the harness sits, not a trusted repo;
  # `--dangerously-bypass-approvals-and-sandbox` is NOT passed — the judge
  # only reads the prompt and writes text.
  #
  # The default bin is an explicit path: /usr/bin/codex (0.140, the system
  # package) predates gpt-5.6-sol and shadows the npm 0.144 install on PATH.
  module CodexJudge
    Error = JudgeOutput::Error

    DEFAULT_TIMEOUT = 1800 # sol at xhigh reasons long on big diffs
    DEFAULT_BIN = File.expand_path("~/.local/share/mise/installs/node/26.2.0/bin/codex")
    DEFAULT_MODEL = "gpt-5.6-sol"
    DEFAULT_EFFORT = "xhigh"

    module_function

    # Returns a judge_fn: ->(prompt:, seed:) => { score:, reason: }.
    def judge_fn(bin: DEFAULT_BIN, model: DEFAULT_MODEL, effort: DEFAULT_EFFORT,
                 timeout_s: DEFAULT_TIMEOUT)
      lambda do |prompt:, seed:|
        _ = seed
        argv = ["timeout", timeout_s.to_s, bin, "exec", "--skip-git-repo-check"]
        argv += ["-m", model] if model
        argv += ["--config", "model_reasoning_effort=#{effort}"] if effort
        argv << "-"
        out, err, status = Open3.capture3(*argv, stdin_data: prompt.to_s)
        raise Error, "codex judge timed out after #{timeout_s}s" if status.exitstatus == 124

        unless status.success?
          # Codex prints a long CLI banner (and sometimes the prompt) before the
          # provider error. Classify the complete stream before truncating it so
          # rejudge's short warning still carries a machine-readable limit marker.
          limit = AgentLimit.limit_hit?(err) ? "limits_reached: " : ""
          raise Error, "#{limit}codex judge exited #{status.exitstatus}: #{err.strip[0, 300]}"
        end

        JudgeOutput.parse_score(out)
      end
    end
  end
end
