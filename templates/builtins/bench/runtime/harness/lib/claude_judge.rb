# frozen_string_literal: true

require "open3"
require "json"
require "lib/judge_output"
require "lib/agent_limit"

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

    MISE_VERSION_LINE = /\Amise\s+\S+\s+tools:\s+claude@\S+\z/i.freeze
    CLAUDE_STDOUT_LIMIT_BANNER =
      /\Ayou(?:'ve| have) hit your (?:usage|session) limit\s*·\s*resets\s+\S.+\z/i.freeze
    CLAUDE_STDOUT_CREDITS_BANNER = Regexp.new(
      "\\Ayou're out of usage credits\\. switch to another model, or manage usage credits at " \
      "claude\\.ai/settings/usage\\?from=cc_cli_limit_message, to continue\\.\\z",
      Regexp::IGNORECASE
    ).freeze

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
        argv = [ "timeout", timeout_s.to_s, bin, "-p" ]
        argv += [ "--model", model ] if model
        out, err, status = Open3.capture3(*argv, stdin_data: prompt.to_s)
        raise Error, "claude judge timed out after #{timeout_s}s" if status.exitstatus == 124

        unless status.success?
          if (limit_detail = trusted_limit_detail(out:, err:))
            raise ProviderLimitError, "claude judge exited #{status.exitstatus}: #{limit_detail[0, 300]}"
          end

          detail = err.strip
          detail = out.strip if detail.empty?
          raise Error, "claude judge exited #{status.exitstatus}: #{detail[0, 300]}"
        end

        JudgeOutput.parse_score(out)
      end
    end

    # Kept for the existing unit tests / callers; delegates to the shared parser.
    def parse_score(text) = JudgeOutput.parse_score(text)

    # Claude CLI 2.1.233 prints its subscription wall to stdout and exits 1.
    # Keep stdout classification deliberately narrower than the shared stderr
    # classifier: trust only the exact standalone reset banner or a structured
    # failed-result envelope whose API status and result both prove quota.
    # Arbitrary model prose about limits must never manufacture retry evidence.
    def trusted_limit_detail(out:, err:)
      stderr = err.to_s.strip
      return stderr if AgentLimit.limit_hit?(stderr)

      lines = AgentLimit.normalize(out).lines.map(&:strip).reject(&:empty?)
      lines.reject! { |line| line.match?(MISE_VERSION_LINE) }
      line = lines.first if lines.one?
      return unless line
      return line if line.match?(CLAUDE_STDOUT_LIMIT_BANNER) || line.match?(CLAUDE_STDOUT_CREDITS_BANNER)

      structured_limit_detail(line)
    end

    def structured_limit_detail(line)
      result = JSON.parse(line)
      return unless result.is_a?(Hash) && result["type"] == "result" && result["is_error"] == true
      return unless result["terminal_reason"] == "api_error" && result["api_error_status"] == 429

      detail = result["result"].to_s
      detail if AgentLimit.limit_hit?(detail)
    rescue JSON::ParserError
      nil
    end
  end
end
