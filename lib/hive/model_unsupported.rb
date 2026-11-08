require "hive/agent_limit"

module Hive
  # A provider refused the configured model outright (for example Codex on a
  # ChatGPT account answering `The 'gpt-6-sol' model is not supported when
  # using Codex with a ChatGPT account.`). This is an operator-owned
  # configuration problem, not a provider quota wall: the same request fails
  # identically on every retry until someone changes the model configured for
  # that stage/role. It is therefore classified apart from AgentLimit's
  # `limits_reached` so it never enters the hourly provider cooldown, the
  # babysitter limit hold, or the daemon healer's automatic retry.
  #
  # Supersedes PR #1473's classification, which treated this response as a
  # plan-allowance wall: in the field (Oct 2026) four review tasks retried
  # ~240 times over ~11 days because triage was configured with a model the
  # account could not use.
  module ModelUnsupported
    REASON = "model_unsupported".freeze

    PATTERNS = [
      /model is not supported when using codex with a chatgpt account/i
    ].freeze

    # Captures the model name from the provider sentence. Quotes may survive
    # JSON escaping (`\'gpt-6-sol\'`), so strip backslashes before matching.
    MODEL_RE = /\bthe\s+['"`‘’]([^'"`‘’\s]{1,128})['"`‘’]\s+model is not supported\b/i.freeze

    # Hive's own formatted error (see `error_message`). Recognized so a
    # message that has already been classified once — and then forwarded
    # through a reviewer/triage/fix result — still reads as this class.
    OWN_MESSAGE_RE = /\Amodel unsupported(?: for [a-z0-9_-]+)?:/i.freeze
    OWN_MODEL_RE = /^model unsupported(?: for [a-z0-9_-]+)?: '([^'\s]{1,128})' is not available\b/i.freeze

    CONFIG_HINT = "set a supported model for this stage/role in " \
                  ".hive-state/config.yml (models routing), then retry the task".freeze

    module_function

    def detected?(text)
      lines(text).any? do |line|
        line.match?(OWN_MESSAGE_RE) || PATTERNS.any? { |pattern| line.match?(pattern) }
      end
    end

    def marker?(attrs)
      return false unless attrs.respond_to?(:[])

      (attrs["reason"] || attrs[:reason]).to_s == REASON
    end

    def model_name(text)
      normalized = Hive::AgentLimit.normalize(text).delete("\\")
      match = normalized.match(MODEL_RE) || normalized.match(OWN_MODEL_RE)
      match && match[1]
    end

    # Single-line, operator-facing message that names the model and the fix.
    # Kept short enough to survive the 200-byte marker-message caps used by
    # several stage boundaries.
    def error_message(text, agent: nil)
      prefix = "model unsupported"
      prefix = "#{prefix} for #{agent}" if agent && !agent.to_s.empty?
      model = model_name(text)
      subject = model ? "'#{model}' is not available to this account" : "the configured model is not available to this account"
      "#{prefix}: #{subject}; #{CONFIG_HINT}"
    end

    # Hive's own formatted line when the text already carries one (it names
    # the agent, the model and the fix); otherwise format the raw provider
    # text so every surface shows both the model and the remedy.
    def operator_message(text, agent: nil)
      lines(text).find { |line| line.match?(OWN_MESSAGE_RE) } ||
        error_message(text, agent: agent)
    end

    # Remediation shown on recovery receipts and the operational status row.
    def remediation(attrs = {})
      message = attrs.respond_to?(:[]) ? (attrs["message"] || attrs[:message]).to_s : ""
      return message unless message.strip.empty?

      "the provider rejected the configured model; #{CONFIG_HINT}"
    end

    def lines(text)
      Hive::AgentLimit.normalize(text).each_line.map(&:strip).reject(&:empty?)
    end
    private_class_method :lines
  end
end
